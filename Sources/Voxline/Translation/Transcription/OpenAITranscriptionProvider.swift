import Foundation
import VoxlineCore

/// Audio Transcriptions protocol: WAV upload and verbose_json segment timestamps.
public struct OpenAITranscriptionProvider: TranscriptionProvider {
    private let settings: TranscriptionSettings
    private let apiKey: String
    private let session: URLSession
    private let evidenceDirectory: URL
    private let onProgress: @Sendable (TranscriptionProgress) -> Void

    public init(settings: TranscriptionSettings, apiKey: String, session: URLSession = .shared,
                evidenceDirectory: URL? = nil, mediaID: UUID = UUID(),
                onProgress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }) throws {
        try settings.validate()
        guard settings.provider == .openAICompatible else { throw CloudTranscriptionError.invalidConfiguration }
        self.settings = settings; self.apiKey = apiKey; self.session = session; self.onProgress = onProgress
        self.evidenceDirectory = (evidenceDirectory ?? URL.cachesDirectory.appendingPathComponent("Voxline/Transcription"))
            .appendingPathComponent(mediaID.uuidString)
    }

    public func transcribe(audio: TranscriptionAudio) async throws -> [RawTranscriptionSegment] {
        try await transcribeEvidence(audio: audio).segments
    }

    public func transcribeEvidence(audio: TranscriptionAudio) async throws -> TranscriptionEvidence {
        var evidence = TranscriptionEvidence(settings: settings, audio: audio)
        var uploadURL: URL?
        do {
            try Task.checkCancellation()
            onProgress(.readingAudio)
            let size = try audio.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size > 0 else { throw CloudTranscriptionError.emptyAudio }
            guard size <= 25_000_000 else { throw CloudTranscriptionError.uploadTooLarge }
            let boundary = "Voxline-\(UUID().uuidString)"
            let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).multipart")
            uploadURL = bodyURL
            try writeMultipart(audio: audio, to: bodyURL, boundary: boundary)
            guard let cloud = settings.cloud else { throw CloudTranscriptionError.invalidConfiguration }
            var request = URLRequest(url: cloud.baseURL.appendingPathComponent("audio/transcriptions"))
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            let delegate = AudioUploadProgress(onProgress: onProgress)
            let (data, response) = try await session.upload(for: request, fromFile: bodyURL, delegate: delegate)
            try FileManager.default.removeItem(at: bodyURL)
            uploadURL = nil
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw CloudTranscriptionError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else {
                // Never expose upstream bodies containing credentials or unrelated private data.
                throw CloudTranscriptionError.http(status: response.statusCode, requestID: response.value(forHTTPHeaderField: "x-request-id"))
            }
            let result = try JSONDecoder().decode(VerboseTranscription.self, from: data)
            evidence.partialDecodedText = result.text
            guard !result.segments.isEmpty || result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CloudTranscriptionError.invalidResponse
            }
            let offset = Double(audio.sourceStartMilliseconds) / 1000
            evidence.segments = result.segments.map {
                .init(startSeconds: $0.start + offset, endSeconds: $0.end + offset, text: $0.text,
                      words: nil, averageLogProbability: $0.avg_logprob, noSpeechProbability: $0.no_speech_prob)
            }
            // No invented word probabilities or alignment. The existing segmenter validates raw segment times.
            evidence.partialDecodedText = nil
            evidence.outcome = .completed
            _ = try persist(evidence)
            onProgress(.completed(segmentCount: evidence.segments.count))
            return evidence
        } catch {
            var reason = error.localizedDescription
            if let uploadURL {
                do { try FileManager.default.removeItem(at: uploadURL) }
                catch let cleanupError { reason += " 上传临时文件清理失败：\(cleanupError.localizedDescription)" }
            }
            evidence.outcome = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
            evidence.failureReason = reason
            let evidenceURL: URL
            do { evidenceURL = try persist(evidence) }
            catch let storageError {
                throw TranscriptionFailure(cause: error, evidence: evidence, evidenceURL: nil, storageError: storageError.localizedDescription)
            }
            throw TranscriptionFailure(cause: error, evidence: evidence, evidenceURL: evidenceURL)
        }
    }

    func writeMultipart(audio: TranscriptionAudio, to url: URL, boundary: String) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: url)
        let input = try FileHandle(forReadingFrom: audio.localURL)
        // File handles close before URLSession reads or cleanup removes the temporary body.
        defer { output.closeFile(); input.closeFile() }
        let fields = [("model", settings.modelID), ("response_format", "verbose_json"), ("timestamp_granularities[]", "segment")]
            + (settings.languageCode.map { [("language", $0)] } ?? [])
        for (name, value) in fields {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    private func persist(_ evidence: TranscriptionEvidence) throws -> URL {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let url = evidenceDirectory.appendingPathComponent("\(UUID()).json")
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        try encoder.encode(evidence).write(to: url, options: .atomic)
        return url
    }
}

private struct VerboseTranscription: Decodable {
    let text: String
    let segments: [Segment]
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
        let avg_logprob: Double?
        let no_speech_prob: Double?
    }
}

private final class AudioUploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (TranscriptionProgress) -> Void
    init(onProgress: @escaping @Sendable (TranscriptionProgress) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(.uploadingAudio(sentBytes: totalBytesSent, totalBytes: totalBytesExpectedToSend))
        if totalBytesExpectedToSend > 0, totalBytesSent == totalBytesExpectedToSend { onProgress(.awaitingTranscription) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // A new destination must be configured explicitly before uploading audio or authentication.
        completionHandler(nil)
    }
}
