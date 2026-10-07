import Foundation
import Synchronization
import Testing
import VoxlineCore
@testable import VoxlineTranslation

@Suite("Cloud transcription protocol", .serialized)
struct CloudTranscriptionTests {
    private func settings() throws -> TranscriptionSettings {
        try CloudTranscriptionServiceConfig(name: "ASR", baseURL: URL(string: "https://asr.example/v1")!).settings(languageCode: "en")
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ASRStubProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func verboseResultKeepsAbsoluteTimesAndCommitsThroughExistingSegmenter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("private-source.wav")
        try Data("RIFF test upload bytes".utf8).write(to: audioURL)
        let audio = try TranscriptionAudio(localURL: audioURL, sourceStartMilliseconds: 120_000, durationMilliseconds: 2000)
        let settings = try settings()
        ASRStubProtocol.response.withLock { $0 = (200, Data(#"{"text":"Hello.","segments":[{"start":0.25,"end":1.5,"text":"Hello.","avg_logprob":-0.1}]}"#.utf8)) }
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = try OpenAITranscriptionProvider(settings: settings, apiKey: "test-only-key", session: session, evidenceDirectory: root)
        let evidence = try await provider.transcribeEvidence(audio: audio)
        #expect(evidence.outcome == .completed)
        #expect(evidence.segments.first?.startSeconds == 120.25)
        #expect(evidence.segments.first?.endSeconds == 121.5)
        #expect(evidence.segments.first?.words == nil)
        #expect(evidence.segments.first?.timingSource == .service)
        #expect(evidence.segments.first?.averageLogProbability == -0.1)
        let result = try SubtitleSegmenter.segment(evidence, sourceID: UUID(), mediaDurationMilliseconds: 122_000)
        #expect(result.cues.first?.startMilliseconds == 120_250)
        #expect(result.cues.first?.sourceText == "Hello.")
        let request = try #require(ASRStubProtocol.lastRequest.withLock { $0 })
        #expect(request.url?.path == "/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        #expect(files.contains { $0.hasSuffix(".json") })
    }

    @Test func failuresNeverRetryAndRetainEvidenceWithoutUpstreamPrivateBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.wav")
        try Data("audio".utf8).write(to: url)
        let audio = try TranscriptionAudio(localURL: url, sourceStartMilliseconds: 0, durationMilliseconds: 1000)
        let session = session()
        defer { session.invalidateAndCancel() }
        ASRStubProtocol.response.withLock { $0 = (503, Data("private-upstream-value".utf8)) }
        ASRStubProtocol.count.withLock { $0 = 0 }
        let provider = try OpenAITranscriptionProvider(settings: settings(), apiKey: "", session: session, evidenceDirectory: root)
        do { _ = try await provider.transcribeEvidence(audio: audio); Issue.record("Expected failure") }
        catch let error as TranscriptionFailure {
            #expect(error.evidence.outcome == .failed)
            #expect(error.localizedDescription.contains("503"))
            #expect(!error.localizedDescription.contains("private-upstream-value"))
            #expect(error.evidenceURL != nil)
        }
        #expect(ASRStubProtocol.count.withLock { $0 } == 1)
        ASRStubProtocol.response.withLock { $0 = (200, Data(#"{"text":"Unaligned text","segments":[]}"#.utf8)) }
        do { _ = try await provider.transcribeEvidence(audio: audio); Issue.record("Missing timestamps accepted") }
        catch let error as TranscriptionFailure {
            #expect(error.evidence.outcome == .failed)
            #expect(error.evidence.partialDecodedText == "Unaligned text")
        }
    }

    @Test func multipartUsesProtocolFieldsAndCancellationWaitsForHTTPToStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0x52, 0x49, 0x46, 0x46, 0, 255, 42])
        let input = root.appendingPathComponent("private-source.wav")
        let body = root.appendingPathComponent("body.multipart")
        try bytes.write(to: input)
        let audio = try TranscriptionAudio(localURL: input, sourceStartMilliseconds: 0, durationMilliseconds: 1000)
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = try OpenAITranscriptionProvider(settings: settings(), apiKey: "test-only-key", session: session, evidenceDirectory: root)
        try provider.writeMultipart(audio: audio, to: body, boundary: "test-boundary")
        let payload = try Data(contentsOf: body)
        let text = String(decoding: payload, as: UTF8.self)
        for value in ["name=\"model\"\r\n\r\nwhisper-1", "name=\"response_format\"\r\n\r\nverbose_json",
                      "name=\"timestamp_granularities[]\"\r\n\r\nsegment", "name=\"language\"\r\n\r\nen"] {
            #expect(text.contains(value))
        }
        #expect(payload.range(of: bytes) != nil)
        #expect(!text.contains("private-source"))
        #expect(!text.contains("test-only-key"))
        #expect(text.hasSuffix("\r\n--test-boundary--\r\n"))
        ASRStubProtocol.hanging.withLock { $0 = true }
        ASRStubProtocol.count.withLock { $0 = 0 }
        ASRStubProtocol.stopped.withLock { $0 = false }
        defer { ASRStubProtocol.hanging.withLock { $0 = false } }
        let work = Task { try await provider.transcribeEvidence(audio: audio) }
        for _ in 0..<100 {
            if ASRStubProtocol.count.withLock({ $0 }) > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ASRStubProtocol.count.withLock { $0 } == 1)
        work.cancel()
        do { _ = try await work.value; Issue.record("Cancelled request succeeded") }
        catch let error as TranscriptionFailure {
            #expect(error.isCancelled)
            #expect(error.evidenceURL != nil)
        }
        #expect(ASRStubProtocol.stopped.withLock { $0 })
    }

    @Test func geminiContractAndModelTimingsRemainReviewableAndInvalidAlignmentKeepsRecognition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("speech.wav")
        try Data("RIFF".utf8).write(to: url)
        let audio = try TranscriptionAudio(localURL: url, sourceStartMilliseconds: 5000, durationMilliseconds: 2000)
        let settings = try CloudTranscriptionServiceConfig(name: "Gemini", baseURL: URL(string: "https://asr.example/openai")!,
            modelID: "gemini-test", protocolKind: .geminiAudioChat).settings(languageCode: "en")
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = try AudioChatTranscriptionProvider(settings: settings, apiKey: "test-key", session: session, evidenceDirectory: root)
        let request = try #require(JSONSerialization.jsonObject(with: provider.requestBody(audioData: Data("RIFF".utf8), duration: 2)) as? [String: Any])
        let messages = try #require(request["messages"] as? [[String: Any]])
        let parts = try #require(messages.first?["content"] as? [[String: Any]])
        let input = try #require(parts.last?["input_audio"] as? [String: String])
        #expect(input == ["data": "UklGRg==", "format": "wav"])
        #expect(request["asr_options"] == nil)
        func response(_ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": text]]]])
        }
        ASRStubProtocol.response.withLock { $0 = (200, try! response(#"{"text":"Hello.","segments":[{"start":0.2,"end":1.5,"text":"Hello."}]}"#)) }
        let evidence = try await provider.transcribeEvidence(audio: audio)
        #expect(evidence.segments.first?.timingSource == .modelGenerated)
        let cues = try SubtitleSegmenter.segment(evidence, sourceID: UUID(), mediaDurationMilliseconds: 7000).cues
        #expect(cues.first?.requiresTimingReview == true)
        #expect(cues.first?.startMilliseconds == 5200)
        #expect(ASRStubProtocol.lastRequest.withLock { $0?.url?.path } == "/openai/chat/completions")
        ASRStubProtocol.response.withLock { $0 = (200, try! response(#"{"text":"Hello.","segments":[{"start":1.8,"end":9.5,"text":"Hello."}]}"#)) }
        do { _ = try await provider.transcribeEvidence(audio: audio); Issue.record("Invalid model timing accepted") }
        catch let error as TranscriptionFailure {
            #expect(error.evidence.cloudResult?.text == "Hello.")
            #expect(error.evidence.cloudResult?.segments?.first?.end == 9.5)
            #expect(throws: (any Error).self) { try CloudTranscriptionAlignment.completedEvidence(from: error.evidence) }
        }
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".response.json") })
    }

    @Test func qwenDataURLTextOnlyFiniteBackoffSilenceAndTruncation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("speech.wav")
        try Data("RIFF".utf8).write(to: url)
        let audio = try TranscriptionAudio(localURL: url, sourceStartMilliseconds: 3000, durationMilliseconds: 2000)
        let settings = try CloudTranscriptionServiceConfig(name: "Qwen", baseURL: URL(string: "https://asr.example/v1")!,
            modelID: "qwen3-asr-flash", protocolKind: .qwenAudioChat).settings(languageCode: "en")
        let session = session()
        defer { session.invalidateAndCancel() }
        let delays = Mutex<[TimeInterval]>([])
        let provider = try AudioChatTranscriptionProvider(settings: settings, apiKey: "", session: session,
            evidenceDirectory: root, wait: { delay in delays.withLock { $0.append(delay) } })
        let request = try #require(JSONSerialization.jsonObject(with: provider.requestBody(audioData: Data("RIFF".utf8), duration: 2)) as? [String: Any])
        let messages = try #require(request["messages"] as? [[String: Any]])
        let parts = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(parts.count == 1)
        #expect(parts.first?["input_audio"] as? [String: String] == ["data": "data:audio/wav;base64,UklGRg=="])
        #expect((request["asr_options"] as? [String: Any])?["language"] as? String == "en")
        #expect(request["response_format"] == nil)
        ASRStubProtocol.response.withLock { $0 = (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"你好。"}}]}"#.utf8)) }
        ASRStubProtocol.statuses.withLock { $0 = [429, 503] }
        defer { ASRStubProtocol.statuses.withLock { $0 = [] } }
        let evidence = try await provider.transcribeEvidence(audio: audio)
        #expect(delays.withLock { $0 } == [0, 0])
        #expect(evidence.segments.first?.startSeconds == 3)
        #expect(evidence.segments.first?.endSeconds == 5)
        #expect(evidence.segments.first?.timingSource == .audioRange)
        #expect(try SubtitleSegmenter.segment(evidence, sourceID: UUID(), mediaDurationMilliseconds: 5000).cues.first?.requiresTimingReview == true)
        ASRStubProtocol.response.withLock { $0.0 = 503 }
        ASRStubProtocol.count.withLock { $0 = 0 }
        do { _ = try await provider.transcribeEvidence(audio: audio); Issue.record("Retry limit missing") }
        catch let error as TranscriptionFailure { #expect(error.localizedDescription.contains("503")) }
        #expect(ASRStubProtocol.count.withLock { $0 } == 4)
        ASRStubProtocol.response.withLock { $0 = (200, Data(#"{"choices":[{"finish_reason":"length","message":{"content":"Partial text"}}]}"#.utf8)) }
        do { _ = try await provider.transcribeEvidence(audio: audio); Issue.record("Truncated response accepted") }
        catch let error as TranscriptionFailure { #expect(error.evidence.partialDecodedText == "Partial text") }
        ASRStubProtocol.count.withLock { $0 = 0 }
        let silent = try TranscriptionAudio(localURL: url, sourceStartMilliseconds: 0, durationMilliseconds: 10_000, isSilent: true)
        #expect(try await provider.transcribeEvidence(audio: silent).segments.isEmpty)
        #expect(ASRStubProtocol.count.withLock { $0 } == 0)
        let long = try TranscriptionAudio(localURL: url, sourceStartMilliseconds: 0, durationMilliseconds: 10_000)
        await #expect(throws: TranscriptionFailure.self) { try await provider.transcribeEvidence(audio: long) }
    }

    @Test @MainActor func metadataHasNoKeyAndEndpointChangesRequireExplicitRebinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("services.json")
        let vault = TestCredentialVault()
        let store = CloudTranscriptionServiceStore(storageURL: url, vault: vault, autoLoad: false)
        var service = CloudTranscriptionServiceConfig(name: "ASR", baseURL: URL(string: "https://asr.example/v1")!)
        try await store.addOrUpdate(service, apiKey: "test-only-key")
        let frozen = try service.settings()
        #expect(try await store.apiKey(for: frozen) == "test-only-key")
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("test-only-key"))
        service.baseURL = URL(string: "https://other.example/v1")!
        try await store.addOrUpdate(service, apiKey: "new-key")
        await #expect(throws: CloudTranscriptionError.changedEndpoint) { try await store.apiKey(for: frozen) }
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(frozen)) as? [String: Any])
        var oldCloud = try #require(old["cloud"] as? [String: Any])
        oldCloud["protocolKind"] = nil
        old["cloud"] = oldCloud
        let oldBytes = try JSONSerialization.data(withJSONObject: old)
        #expect(try JSONDecoder().decode(TranscriptionSettings.self, from: oldBytes) == frozen)
        oldCloud["protocolKind"] = "unsupported-protocol"
        old["cloud"] = oldCloud
        let invalidBytes = try JSONSerialization.data(withJSONObject: old)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TranscriptionSettings.self, from: invalidBytes) }
        let historical = try JSONEncoder().encode(TranscriptionSettings.whisperKitBaseline)
        #expect(try JSONDecoder().decode(TranscriptionSettings.self, from: historical).cloud == nil)
        let task = ProcessingTask(parameters: .init(transcription: frozen, translation: nil, srtOutputs: [.source]))
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task)).parameters.transcription == frozen)
        var oldTask = try #require(JSONSerialization.jsonObject(with: TaskDocumentCodec.encode(task)) as? [String: Any])
        oldTask["formatVersion"] = 5
        var oldParameters = try #require(oldTask["parameters"] as? [String: Any])
        oldParameters["transcription"] = try JSONSerialization.jsonObject(with: oldBytes)
        oldTask["parameters"] = oldParameters
        let migrated = try TaskDocumentCodec.decode(JSONSerialization.data(withJSONObject: oldTask))
        #expect(migrated == task && migrated.formatVersion == 6)
    }
}

private final class ASRStubProtocol: URLProtocol, @unchecked Sendable {
    static let response = Mutex((200, Data()))
    static let statuses = Mutex<[Int]>([])
    static let lastRequest = Mutex<URLRequest?>(nil)
    static let count = Mutex(0)
    static let hanging = Mutex(false)
    static let stopped = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest.withLock { $0 = request }
        Self.count.withLock { $0 += 1 }
        if Self.hanging.withLock({ $0 }) { return }
        let (defaultStatus, data) = Self.response.withLock { $0 }
        let status = Self.statuses.withLock { $0.isEmpty ? defaultStatus : $0.removeFirst() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["x-request-id":"test-request", "Retry-After":"0"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stopped.withLock { $0 = true } }
}
