import Foundation
import VoxlineCore

/// Vendor presets share transport while preserving their distinct audio and response contracts.
public struct AudioChatTranscriptionProvider: TranscriptionProvider {
    private let settings: TranscriptionSettings
    private let apiKey: String
    private let session: URLSession
    private let evidenceDirectory: URL
    private let onProgress: @Sendable (TranscriptionProgress) -> Void
    private let padShortAudio: @Sendable (TranscriptionAudio) throws -> Data
    private let wait: @Sendable (TimeInterval) async throws -> Void

    public init(settings: TranscriptionSettings, apiKey: String,
                padShortAudio: @escaping @Sendable (TranscriptionAudio) throws -> Data, session: URLSession = .shared,
                evidenceDirectory: URL? = nil, mediaID: UUID = UUID(),
                onProgress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in },
                wait: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) throws {
        try settings.validate()
        guard settings.cloud?.protocolKind.usesSpeechChunks == true else { throw CloudTranscriptionError.invalidConfiguration }
        self.settings = settings; self.apiKey = apiKey; self.session = session
        self.onProgress = onProgress; self.wait = wait
        self.padShortAudio = padShortAudio
        self.evidenceDirectory = (evidenceDirectory ?? URL.cachesDirectory.appendingPathComponent("Voxline/Transcription"))
            .appendingPathComponent(mediaID.uuidString)
    }

    public func transcribe(audio: TranscriptionAudio) async throws -> TranscriptionEvidence {
        var evidence = TranscriptionEvidence(settings: settings, audio: audio)
        do {
            try Task.checkCancellation()
            if audio.isSilent {
                evidence.cloudResult = .init(text: "", segments: nil, timingSource: .audioRange)
            } else {
                guard audio.durationMilliseconds <= 8000 else { throw CloudTranscriptionError.audioChunkTooLong }
                onProgress(.readingAudio)
                guard let cloud = settings.cloud else { throw CloudTranscriptionError.invalidConfiguration }
                let size = try audio.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let size, size > 0 else { throw CloudTranscriptionError.emptyAudio }
                // Eight seconds of PCM16 remains far below both vendors' encoded limits.
                guard size <= 1_000_000 else { throw CloudTranscriptionError.uploadTooLarge }
                let audioData = cloud.protocolKind == .qwenAudioChat && audio.durationMilliseconds < 1000
                    ? try padShortAudio(audio) : try Data(contentsOf: audio.localURL)
                let payload = try requestBody(audioData: audioData, duration: Double(audio.durationMilliseconds) / 1000)
                var request = URLRequest(url: cloud.baseURL.appendingPathComponent("chat/completions"))
                request.httpMethod = "POST"; request.timeoutInterval = 300
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                let delegate = AudioUploadProgress(onProgress: onProgress)
                var attempt = 0
                let responseData: Data
                while true {
                    try Task.checkCancellation()
                    let (data, response) = try await session.upload(for: request, from: payload, delegate: delegate)
                    guard let http = response as? HTTPURLResponse else { throw CloudTranscriptionError.invalidResponse }
                    if (200..<300).contains(http.statusCode) { responseData = data; break }
                    if [429, 503].contains(http.statusCode), attempt < 3 {
                        attempt += 1
                        let delay = HTTPRetryDelay.seconds(retryAfter: http.value(forHTTPHeaderField: "Retry-After"), attempt: attempt)
                        onProgress(.retryingAudio(attempt: attempt, delaySeconds: delay))
                        try await wait(delay)
                        continue
                    }
                    throw CloudTranscriptionError.http(status: http.statusCode, requestID: http.value(forHTTPHeaderField: "x-request-id"))
                }
                // Preserve successful raw recognition even if structural parsing or timing later fails.
                CloudTranscriptionEvidence.recordResponse(responseData, to: evidenceDirectory)
                let response = try JSONDecoder().decode(ChatResponse.self, from: responseData)
                guard response.choices.count == 1, let choice = response.choices.first else { throw CloudTranscriptionError.invalidResponse }
                evidence.partialDecodedText = choice.message.content
                guard choice.finish_reason == "stop" else { throw CloudTranscriptionError.incompleteResponse(choice.finish_reason ?? "missing") }
                guard let content = choice.message.content else { throw CloudTranscriptionError.invalidResponse }
                if cloud.protocolKind == .geminiAudioChat {
                    let value = try JSONDecoder().decode(GeminiTranscript.self, from: Data(content.utf8))
                    evidence.cloudResult = .init(text: value.text, segments: value.segments?.map {
                        .init(start: $0.start, end: $0.end, text: $0.text)
                    },
                        timingSource: value.segments == nil ? .audioRange : .modelGenerated)
                } else {
                    evidence.cloudResult = .init(text: content, segments: nil, timingSource: .audioRange)
                }
            }
            try Task.checkCancellation()
            evidence = try CloudTranscriptionAlignment.completedEvidence(from: evidence)
            CloudTranscriptionEvidence.recordCompleted(evidence, to: evidenceDirectory)
            onProgress(.completed(segmentCount: evidence.segments.count))
            return evidence
        } catch {
            evidence.outcome = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
            evidence.failureReason = error.localizedDescription
            let url: URL
            do { url = try CloudTranscriptionEvidence.write(evidence, to: evidenceDirectory) }
            catch let storageError { throw TranscriptionFailure(cause: error, evidence: evidence, evidenceURL: nil, storageError: storageError.localizedDescription) }
            throw TranscriptionFailure(cause: error, evidence: evidence, evidenceURL: url)
        }
    }

    func requestBody(audioData: Data, duration: Double) throws -> Data {
        guard let cloud = settings.cloud else { throw CloudTranscriptionError.invalidConfiguration }
        let base64 = audioData.base64EncodedString()
        var payload: [String: Any] = ["model": settings.modelID, "stream": false]
        if cloud.protocolKind == .geminiAudioChat {
            let language = settings.languageCode.map { "The speech language is \($0)." } ?? "Detect the speech language."
            let prompt = "Transcribe only audible speech in its original language. \(language) Return JSON {\"text\":string,\"segments\":[{\"start\":number,\"end\":number,\"text\":string}]}. Times are seconds relative to this audio, within 0...\(duration). Segments must be ordered, non-overlapping and contain all text. For silence return empty text and segments. Do not translate, invent speech, or add commentary."
            payload["messages"] = [["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "input_audio", "input_audio": ["data": base64, "format": "wav"]]
            ]]]
            payload["response_format"] = ["type": "json_object"]
        } else {
            payload["messages"] = [["role": "user", "content": [
                ["type": "input_audio", "input_audio": ["data": "data:audio/wav;base64,\(base64)"]]
            ]]]
            var options: [String: Any] = ["enable_itn": false]
            if let language = settings.languageCode { options["language"] = language }
            payload["asr_options"] = options
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

}

private struct ChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        let finish_reason: String?
        struct Message: Decodable { let content: String? }
    }
}
private struct GeminiTranscript: Decodable {
    let text: String
    let segments: [Segment]?
    struct Segment: Decodable { let start: Double; let end: Double; let text: String }

    private enum CodingKeys: String, CodingKey { case text, segments }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        do { segments = try container.decodeIfPresent([Segment].self, forKey: .segments) }
        catch is DecodingError {
            // Optional model annotations may be incomplete; the raw response is retained.
            // The provider marks this as audio-range timing rather than precise alignment.
            segments = nil
        }
    }
}
