import Foundation
import Synchronization
import Testing
import VoxlineCore
@testable import VoxlineTranslation

@Suite("OpenAI compatible subtitle translation", .serialized)
struct SubtitleTranslationTests {
    private func cues(count: Int = 4, text: String = "Put it down.") throws -> [SubtitleCue] {
        try (0..<count).map { index in
            try SubtitleCue(id: UUID(), startMilliseconds: Int64(index * 2000), endMilliseconds: Int64(index * 2000 + 1000), sourceText: text)
        }
    }
    private func response(_ content: String, finish: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "finish_reason": finish,
            "message": ["role": "assistant", "content": content]]]])
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func remoteClientRejectsNativeEngineBeforeNetworkAccess() async throws {
        let cues = try cues(count: 1)
        let settings = try TranslationSettings(appleSourceLanguage: "en", targetLanguage: "zh-Hans")
        let request = try SubtitleTranslationRequest(inputs: cues.map(TranslationBatchInput.init), cues: cues)
        await #expect(throws: SubtitleTranslationError.invalidRequest) {
            try await OpenAICompatibleTranslationClient(session: session()).translate(settings: settings, apiKey: "test", request: request)
        }
    }

    @Test func strictIDsRejectMissingDuplicateExtraBlankAndTimelineFields() throws {
        let cues = try cues(count: 2)
        let valid = cues.map { ["id": $0.id.uuidString, "text": "放下它。"] }
        func parse(_ values: [[String: String]], rootExtra: Bool = false) throws -> [TranslationBatchOutput] {
            var root: [String: Any] = ["translations": values]
            if rootExtra { root["timestamps"] = [] }
            let content = String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            return try OpenAICompatibleTranslationClient.parseResponse(response(content), expectedIDs: cues.map(\.id))
        }
        #expect(try parse(valid.reversed()).map(\.cueID) == cues.reversed().map(\.id))
        for invalid in [Array(valid.dropLast()), [valid[0], valid[0]], valid + [["id": UUID().uuidString, "text": "多余"]],
                        [valid[0], ["id": cues[1].id.uuidString, "text": " "]],
                        [valid[0], ["id": cues[1].id.uuidString, "text": "第二条", "start": "0"]]] {
            #expect(throws: SubtitleTranslationError.invalidTranslationResult) { try parse(invalid) }
        }
        #expect(throws: SubtitleTranslationError.invalidTranslationResult) { try parse(valid, rootExtra: true) }
        #expect(throws: SubtitleTranslationError.invalidTranslationResult) {
            try OpenAICompatibleTranslationClient.parseResponse(response("```json\n{}\n```"), expectedIDs: cues.map(\.id))
        }
        #expect(throws: SubtitleTranslationError.incompleteResponse("length")) {
            try OpenAICompatibleTranslationClient.parseResponse(response("{}", finish: "length"), expectedIDs: cues.map(\.id))
        }
    }

    @Test func batchesRespectUTF8CapacityAndKeepNeighboringContext() throws {
        let cues = try cues(count: 65)
        let batches = try SubtitleTranslationBatchPlanner.batches(cues: cues, pendingIDs: cues.map(\.id), targetLanguage: "zh-Hans")
        #expect(batches.map(\.count) == [30, 30, 5])
        #expect(batches.flatMap { $0 } == cues.map(\.id))
        let request = try SubtitleTranslationRequest(inputs: cues[30..<60].map(TranslationBatchInput.init), cues: cues)
        #expect(request.contextBefore.map(\.id) == cues[28..<30].map(\.id))
        #expect(request.contextAfter.map(\.id) == cues[60..<62].map(\.id))
        let long = try self.cues(count: 8, text: String(repeating: "中", count: 550))
        let bounded = try SubtitleTranslationBatchPlanner.batches(cues: long, pendingIDs: long.map(\.id), targetLanguage: "zh-Hans")
        #expect(bounded.count > 1)
        for ids in bounded {
            let request = try SubtitleTranslationRequest(inputs: long.filter { ids.contains($0.id) }.map(TranslationBatchInput.init), cues: long)
            #expect(try request.payload(targetLanguage: "zh-Hans").count <= SubtitleTranslationBatchPlanner.maximumPayloadBytes)
        }
        let oversized = try self.cues(count: 1, text: String(repeating: "中", count: 5000))
        #expect(throws: SubtitleTranslationError.requestTooLarge) {
            try SubtitleTranslationBatchPlanner.batches(cues: oversized, pendingIDs: oversized.map(\.id), targetLanguage: "zh-Hans")
        }
    }

    @Test func configurableCountRespectsCapacityAndRejectsInvalidOrOversizedClientInput() async throws {
        let cues = try cues(count: 65)
        for (limit, counts) in [(1, Array(repeating: 1, count: 65)), (7, Array(repeating: 7, count: 9) + [2]), (50, [50, 15])] {
            let batches = try SubtitleTranslationBatchPlanner.batches(cues: cues, pendingIDs: cues.map(\.id), targetLanguage: "zh", batchSize: limit)
            #expect(batches.map(\.count) == counts)
            #expect(batches.flatMap { $0 } == cues.map(\.id))
        }
        #expect(throws: ProjectValidationError.invalidTranslationBatchSize) {
            try SubtitleTranslationBatchPlanner.batches(cues: cues, pendingIDs: cues.map(\.id), targetLanguage: "zh", batchSize: 0)
        }
        let long = try self.cues(count: 8, text: String(repeating: "中", count: 550))
        let bounded = try SubtitleTranslationBatchPlanner.batches(cues: long, pendingIDs: long.map(\.id), targetLanguage: "zh", batchSize: 100)
        #expect(bounded.count > 1)
        let input = try SubtitleTranslationRequest(inputs: cues.prefix(3).map(TranslationBatchInput.init), cues: cues)
        let settings = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!, modelID: "test", targetLanguage: "zh", batchSize: 2)
        let connection = session()
        defer { connection.invalidateAndCancel() }
        TranslationStubProtocol.handler.withLock { $0 = { _ in
            Issue.record("Oversized input must fail before sending HTTP")
            throw URLError(.badURL)
        } }
        await #expect(throws: SubtitleTranslationError.requestTooLarge) {
            try await OpenAICompatibleTranslationClient(session: connection).translate(settings: settings, apiKey: "test-only", request: input)
        }
    }

    @Test func actualHTTPBodyUsesFrozenSettingsAndNoTimestamps() async throws {
        let cues = try cues(count: 2)
        let input = try SubtitleTranslationRequest(inputs: cues.map(TranslationBatchInput.init), cues: cues)
        let settings = try TranslationSettings(baseURL: URL(string: "https://test.example/v1/")!, modelID: "chosen-model", targetLanguage: "zh-Hans", batchSize: 2, systemPrompt: "Use concise Simplified Chinese and retain names.")
        let json = try response(String(data: JSONSerialization.data(withJSONObject: ["translations": cues.map { ["id": $0.id.uuidString, "text": "放下它。"] }]), encoding: .utf8)!)
        TranslationStubProtocol.handler.withLock { $0 = { request in
            #expect(request.url?.path == "/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-secret")
            let bodyData: Data
            if let data = request.httpBody { bodyData = data }
            else {
                // URLSession presents the request body as a stream to URLProtocol on macOS.
                let stream = try #require(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                bodyData = data
            }
            let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            #expect(body["model"] as? String == settings.api?.modelID)
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages[0]["role"] == "system")
            let instructions = try #require(messages[0]["content"])
            #expect(instructions.hasPrefix(try #require(settings.api).systemPrompt + "\n"))
            #expect(instructions.contains("Include every subtitles ID exactly once"))
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as? [String: Any])
            #expect(payload["targetLanguage"] as? String == settings.targetLanguage)
            let subtitles = try #require(payload["subtitles"] as? [[String: String]])
            #expect(subtitles.count == 2)
            #expect(subtitles.allSatisfy { Set($0.keys) == ["id", "text"] })
            return (200, [:], json)
        } }
        let connection = session()
        defer { connection.invalidateAndCancel() }
        let outputs = try await OpenAICompatibleTranslationClient(session: connection).translate(settings: settings, apiKey: "test-only-secret", request: input)
        #expect(outputs.count == 2)
        #expect(cues.allSatisfy { $0.sourceText == "Put it down." && $0.translation == .pending })
    }

    @Test func retryAfterAndBackoffDistinguishTemporaryFailures() {
        let now = Date(timeIntervalSince1970: 1445412480)
        #expect(SubtitleTranslationError.rateLimited(retryAfter: "120").retryDelay(attempt: 1, now: now, jitter: 0) == 120)
        #expect(SubtitleTranslationError.temporarilyUnavailable(statusCode: 503, retryAfter: "Wed, 21 Oct 2015 07:30:00 GMT")
            .retryDelay(attempt: 1, now: now, jitter: 0) == 120)
        #expect(SubtitleTranslationError.rateLimited(retryAfter: "Wed, 21 Oct 2015 07:27:00 GMT")
            .retryDelay(attempt: 1, now: now, jitter: 0) == 0)
        for (attempt, delay) in [(1, 5.0), (2, 15.0), (3, 45.0)] {
            #expect(SubtitleTranslationError.temporarilyUnavailable(statusCode: 503, retryAfter: "invalid")
                .retryDelay(attempt: attempt, now: now, jitter: 0) == delay)
            #expect(SubtitleTranslationError.timeout.retryDelay(attempt: attempt, jitter: 1) == delay * 1.2)
        }
        for error in [SubtitleTranslationError.authenticationFailed, .invalidTranslationResult, .httpFailure(400), .connectionFailed] {
            #expect(error.retryDelay(attempt: 1, jitter: 0) == nil)
        }
    }

    @Test func HTTPFailuresAndTimeoutAreExplicitWithoutLeakingResponseBody() async throws {
        let cues = try cues(count: 1)
        let input = try SubtitleTranslationRequest(inputs: cues.map(TranslationBatchInput.init), cues: cues)
        let settings = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!, modelID: "chosen", targetLanguage: "zh")
        let connection = session()
        defer { connection.invalidateAndCancel() }
        let client = OpenAICompatibleTranslationClient(session: connection)
        for (status, expected) in [(401, SubtitleTranslationError.authenticationFailed), (403, .authenticationFailed),
            (429, .rateLimited(retryAfter: "10")), (500, .temporarilyUnavailable(statusCode: 500, retryAfter: "10")), (503, .temporarilyUnavailable(statusCode: 503, retryAfter: "10"))] {
            TranslationStubProtocol.handler.withLock { $0 = { _ in (status, ["Retry-After": "10"], Data("sensitive-upstream-message".utf8)) } }
            await #expect(throws: expected) { try await client.translate(settings: settings, apiKey: "secret", request: input) }
            #expect(!expected.localizedDescription.contains("sensitive-upstream-message"))
        }
        TranslationStubProtocol.handler.withLock { $0 = { _ in throw URLError(.timedOut) } }
        await #expect(throws: SubtitleTranslationError.timeout) { try await client.translate(settings: settings, apiKey: "secret", request: input) }
        TranslationStubProtocol.handler.withLock { $0 = { _ in throw URLError(.cancelled) } }
        await #expect(throws: CancellationError.self) { try await client.translate(settings: settings, apiKey: "secret", request: input) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_TRANSLATION_SERVICE_FILE"] != nil &&
        ProcessInfo.processInfo.environment["VOXLINE_TRANSLATION_API_KEY"] != nil))
    func realConfiguredServiceTranslatesSubtitleIDs() async throws {
        struct Service: Decodable { let id: UUID; let baseURL: URL; let modelID: String }
        let path = try #require(ProcessInfo.processInfo.environment["VOXLINE_TRANSLATION_SERVICE_FILE"])
        let services = try JSONDecoder().decode([Service].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let service = try #require(services.first)
        let apiKey = try #require(ProcessInfo.processInfo.environment["VOXLINE_TRANSLATION_API_KEY"])
        let cues = try ["Freeze!", "Oh hi.", "Put it down.", "The book?"].enumerated().map { index, text in
            try SubtitleCue(id: UUID(), startMilliseconds: Int64(index * 2000), endMilliseconds: Int64(index * 2000 + 1000), sourceText: text)
        }
        let settings = try TranslationSettings(baseURL: service.baseURL, modelID: service.modelID, targetLanguage: "zh-Hans", serviceID: service.id)
        let input = try SubtitleTranslationRequest(inputs: cues.map(TranslationBatchInput.init), cues: cues)
        let output = try await OpenAICompatibleTranslationClient().translate(settings: settings, apiKey: apiKey, request: input)
        #expect(Set(output.map(\.cueID)) == Set(cues.map(\.id)))
        #expect(output.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        #expect(output.contains { result in cues.contains { $0.id == result.cueID && $0.sourceText != result.text } })
        struct Artifact: Encodable { let settings: TranslationSettings; let source: [SubtitleCue]; let outputs: [TranslationBatchOutput] }
        let root = URL(fileURLWithPath: "tmp/translation-validation", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Artifact(settings: settings, source: cues, outputs: output)).write(to: root.appendingPathComponent("real-service.json"), options: .atomic)
        print("Real configured translation: \(output.count) IDs verified; credential excluded from artifact.")
    }
}

private final class TranslationStubProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) throws -> (Int, [String: String], Data))?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let action = try Self.handler.withLock { try #require($0) }
            let (code, headers, data) = try action(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
