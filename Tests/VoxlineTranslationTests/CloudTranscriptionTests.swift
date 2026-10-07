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
        let historical = try JSONEncoder().encode(TranscriptionSettings.whisperKitBaseline)
        #expect(try JSONDecoder().decode(TranscriptionSettings.self, from: historical).cloud == nil)
        let task = ProcessingTask(parameters: .init(transcription: frozen, translation: nil, srtOutputs: [.source]))
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task)).parameters.transcription == frozen)
    }
}

private final class ASRStubProtocol: URLProtocol, @unchecked Sendable {
    static let response = Mutex((200, Data()))
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
        let (status, data) = Self.response.withLock { $0 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["x-request-id":"test-request"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stopped.withLock { $0 = true } }
}
