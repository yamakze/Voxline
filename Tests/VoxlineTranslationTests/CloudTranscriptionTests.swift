import AVFoundation
import Foundation
import Synchronization
import Testing
import VoxlineCore
import VoxlineMedia
@testable import VoxlineTranslation

@Suite("Cloud transcription protocol", .serialized)
struct CloudTranscriptionTests {
    private func settings(modelID: String = "whisper-1", baseURL: URL = URL(string: "https://asr.example/v1")!) throws -> TranscriptionSettings {
        try CloudTranscriptionServiceConfig(name: "ASR", baseURL: baseURL, modelID: modelID).settings(languageCode: "en")
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ASRStubProtocol.self]
        return URLSession(configuration: config)
    }

    @Test(arguments: ["whisper-1", "whisper-large-v3-turbo", "custom-asr-model"])
    func verboseResultKeepsAbsoluteTimesAndCommitsThroughExistingSegmenter(modelID: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("private-source.wav")
        try Data("RIFF test upload bytes".utf8).write(to: audioURL)
        let audio = try TranscriptionAudio(localURL: audioURL, sourceStartMilliseconds: 120_000, durationMilliseconds: 2000)
        let settings = try settings(modelID: modelID, baseURL: URL(string: "http://127.0.0.1:8181/proxy/v1/?api-version=2026-01&route=asr")!)
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
        #expect(request.url?.path == "/proxy/v1/audio/transcriptions")
        #expect(request.url?.host == "127.0.0.1" && request.url?.port == 8181)
        #expect(request.url?.query == "api-version=2026-01&route=asr")
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

    @Test func multipartUsesProtocolFieldsAndCancelsActiveHTTP() async throws {
        let modelID = "whisper-large-v3-turbo"
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
        let provider = try OpenAITranscriptionProvider(settings: settings(modelID: modelID), apiKey: "test-only-key", session: session, evidenceDirectory: root)
        try provider.writeMultipart(audio: audio, to: body, boundary: "test-boundary")
        let payload = try Data(contentsOf: body)
        let text = String(decoding: payload, as: UTF8.self)
        for value in ["name=\"model\"\r\n\r\n\(modelID)", "name=\"response_format\"\r\n\r\nverbose_json",
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
        // URLSession may deliver stopLoading after its cancelled async call returns.
        // Observe the transport callback before this test releases its session and shared stub state.
        for _ in 0..<100 {
            if ASRStubProtocol.stopped.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ASRStubProtocol.stopped.withLock { $0 })
    }

    @Test func geminiContractPreservesRecognitionWhenOptionalModelAlignmentIsUnusable() async throws {
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
        let provider = try AudioChatTranscriptionProvider(settings: settings, apiKey: "test-key", padShortAudio: { try TranscriptionAudioUpload.paddedToOneSecond($0) }, session: session, evidenceDirectory: root)
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
        #expect(cues.first?.startMilliseconds == 5200)
        #expect(ASRStubProtocol.lastRequest.withLock { $0?.url?.path } == "/openai/chat/completions")
        ASRStubProtocol.response.withLock { $0 = (200, try! response(#"{"text":"Hello.","segments":[{"start":1.8,"end":9.5,"text":"Hello."}]}"#)) }
        let padded = try await provider.transcribeEvidence(audio: audio)
        #expect(padded.cloudResult?.segments?.first?.end == 9.5)
        #expect(try SubtitleSegmenter.segment(padded, sourceID: UUID(), mediaDurationMilliseconds: 7000)
            .cues.first?.endMilliseconds == 7000)
        ASRStubProtocol.response.withLock { $0 = (200, try! response(#"{"text":"Hello.","segments":[{"start":2.8,"end":9.5,"text":"Hello."}]}"#)) }
        let coarse = try await provider.transcribeEvidence(audio: audio)
        #expect(coarse.cloudResult?.segments?.first?.end == 9.5)
        #expect(coarse.segments.first?.timingSource == .audioRange)
        let coarseCues = try SubtitleSegmenter.segment(coarse, sourceID: UUID(), mediaDurationMilliseconds: 7000).cues
        #expect(coarseCues.first?.startMilliseconds == 5000)
        #expect(coarseCues.first?.endMilliseconds == 7000)
        for (transcript, annotation) in [("Hello, world!", "Hello world"), ("版本1.5", "版本15"),
                                          ("Temperature -3", "Temperature 3"), ("Don't go.", "Dont go.")] {
            let payload = try JSONSerialization.data(withJSONObject: ["text": transcript,
                "segments": [["start": 0.2, "end": 1.5, "text": annotation]]])
            let body = try response(String(decoding: payload, as: UTF8.self))
            ASRStubProtocol.response.withLock { $0 = (200, body) }
            let preserved = try await provider.transcribeEvidence(audio: audio)
            #expect(preserved.segments.first?.timingSource == .audioRange)
            #expect(preserved.cloudResult?.segments?.first?.text == annotation)
            let cues = try SubtitleSegmenter.segment(preserved, sourceID: UUID(), mediaDurationMilliseconds: 7000).cues
            #expect(cues.map(\.sourceText) == [transcript])
        }
        ASRStubProtocol.response.withLock { $0 = (200, try! response(#"{"text":"Keep every word.","segments":[{"start":0.2,"end":1.5,"text":"Keep word."}]}"#)) }
        let mismatch = try await provider.transcribeEvidence(audio: audio)
        #expect(mismatch.segments.first?.text == "Keep every word.")
        #expect(mismatch.segments.first?.timingSource == .audioRange)
        #expect(mismatch.cloudResult?.segments?.first?.text == "Keep word.")
        ASRStubProtocol.response.withLock { $0 = (200, try! response(#"{"text":"Hello.","segments":[{"start":0.2,"end":1.5}]}"#)) }
        let missingAnnotation = try await provider.transcribeEvidence(audio: audio)
        #expect(missingAnnotation.segments.first?.text == "Hello.")
        #expect(missingAnnotation.segments.first?.timingSource == .audioRange)
        // A valid-looking payload is still incomplete when the service reports truncation.
        let truncated = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length",
            "message": ["content": #"{"text":"Hello.","segments":[]}"#]]]])
        ASRStubProtocol.response.withLock { $0 = (200, truncated) }
        do { _ = try await provider.transcribeEvidence(audio: audio); Issue.record("Truncated recognition accepted") }
        catch let error as TranscriptionFailure {
            #expect(error.evidence.outcome == .failed)
            #expect(error.evidence.cloudResult == nil)
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
        let provider = try AudioChatTranscriptionProvider(settings: settings, apiKey: "", padShortAudio: { try TranscriptionAudioUpload.paddedToOneSecond($0) }, session: session,
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

    @Test func qwenShortPCMUploadsSilenceWithoutChangingRecognitionRange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tail.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        buffer.frameLength = 320
        let samples = try #require(buffer.int16ChannelData?[0])
        for index in 0..<320 { samples[index] = Int16(index - 160) }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true); try file.write(from: buffer) }
        let original = try Data(contentsOf: url)
        let audio = try TranscriptionAudio(localURL: url, sourceStartMilliseconds: 4_130_000, durationMilliseconds: 20)
        let settings = try CloudTranscriptionServiceConfig(name: "Qwen", baseURL: URL(string: "https://asr.example/v1")!,
            modelID: "qwen3-asr-flash", protocolKind: .qwenAudioChat).settings()
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = try AudioChatTranscriptionProvider(settings: settings, apiKey: "", padShortAudio: { try TranscriptionAudioUpload.paddedToOneSecond($0) }, session: session, evidenceDirectory: root)
        let padded = try TranscriptionAudioUpload.paddedToOneSecond(audio)
        let paddedURL = root.appendingPathComponent("padded.wav")
        try padded.write(to: paddedURL)
        let decoded = try AVAudioFile(forReading: paddedURL, commonFormat: .pcmFormatInt16, interleaved: true)
        let decodedBuffer = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 16_000))
        try decoded.read(into: decodedBuffer)
        let decodedSamples = try #require(decodedBuffer.int16ChannelData?[0])
        #expect(decoded.length == 16_000 && decodedBuffer.frameLength == 16_000)
        #expect((0..<320).allSatisfy { decodedSamples[$0] == samples[$0] })
        #expect((320..<16_000).allSatisfy { decodedSamples[$0] == 0 })
        ASRStubProtocol.response.withLock { $0 = (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Tail"}}]}"#.utf8)) }
        let evidence = try await provider.transcribeEvidence(audio: audio)
        #expect(evidence.durationMilliseconds == 20 && evidence.sourceStartMilliseconds == 4_130_000)
        #expect(evidence.segments.first?.endSeconds == 4130.02)
        #expect(evidence.segments.first?.timingSource == .audioRange)
        #expect(try Data(contentsOf: url) == original)
        let inconsistent = try TranscriptionAudio(localURL: url, sourceStartMilliseconds: 0, durationMilliseconds: 80)
        await #expect(throws: TranscriptionFailure.self) { try await provider.transcribeEvidence(audio: inconsistent) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_QWEN_RETRY_FIXTURE"] != nil))
    func realQwenShortRetryKeepsCompletedTaskResults() async throws {
        struct Fixture: Decodable {
            let taskPath: String
            let audioPaths: [String]
        }
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(environment["VOXLINE_QWEN_RETRY_FIXTURE"])
        let key = try #require(environment["VOXLINE_QWEN_API_KEY"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let original = try TaskDocumentCodec.decode(Data(contentsOf: URL(fileURLWithPath: fixture.taskPath)))
        var task = original
        let originalItem = try #require(original.items.first)
        let checkpoint = try #require(originalItem.checkpoint)
        let pending = checkpoint.chunks.filter { !$0.isCompleted }
        #expect(pending.count == fixture.audioPaths.count)
        let root = URL(fileURLWithPath: fixturePath).deletingLastPathComponent().appendingPathComponent("qwen-retry-evidence")
        let provider = try AudioChatTranscriptionProvider(settings: task.parameters.transcription, apiKey: key, padShortAudio: { try TranscriptionAudioUpload.paddedToOneSecond($0) }, evidenceDirectory: root)
        for (chunk, path) in zip(pending, fixture.audioPaths) {
            let audio = try TranscriptionAudio(localURL: URL(fileURLWithPath: path),
                sourceStartMilliseconds: chunk.range.sourceStartMilliseconds, durationMilliseconds: chunk.range.durationMilliseconds)
            let sourceID = try task.items[0].beginTranscriptionChunk(chunk.id)
            let evidence = try await provider.transcribeEvidence(audio: audio)
            let result = try SubtitleSegmenter.segment(evidence, sourceID: sourceID,
                mediaDurationMilliseconds: checkpoint.media.durationMilliseconds)
            try task.items[0].commitTranscriptionChunk(chunk.id, result: result)
        }
        #expect(task.items[0].checkpoint?.chunks.allSatisfy(\.isCompleted) == true)
        for chunk in checkpoint.chunks where chunk.isCompleted {
            #expect(task.items[0].checkpoint?.chunks.first(where: { $0.id == chunk.id }) == chunk)
        }
        for cue in originalItem.cues { #expect(task.items[0].cues.first(where: { $0.id == cue.id }) == cue) }
        #expect(task.parameters == original.parameters)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task)) == task)
    }

    @Test @MainActor func missingOrInvalidProtocolFailsLoadingAndPreservesConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("services.json")
        let vault = TestCredentialVault()
        let store = CloudTranscriptionServiceStore(storageURL: url, vault: vault, autoLoad: false)
        let service = CloudTranscriptionServiceConfig(name: "ASR", baseURL: URL(string: "https://asr.example/v1")!)
        try await store.addOrUpdate(service, apiKey: "test-only-key")
        let frozen = try service.settings()
        let valid = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(service)) as? [String: Any])
        let invalidProtocols: [Any?] = [nil, NSNull(), "unsupported-protocol", 7]
        for value in invalidProtocols {
            var object = valid
            object["protocolKind"] = value
            let broken = try JSONSerialization.data(withJSONObject: [object])
            try broken.write(to: url)
            await store.load()
            #expect(store.errorMessage != nil)
            #expect(store.services == [service])
            #expect(try Data(contentsOf: url) == broken)
            #expect(await vault.read(serviceID: service.id) == "test-only-key")
            await #expect(throws: TranslationServiceError.configurationUnavailable) { try await store.apiKey(for: frozen) }
            let reopened = CloudTranscriptionServiceStore(storageURL: url, vault: vault, autoLoad: false)
            await reopened.load()
            #expect(reopened.errorMessage != nil)
            #expect(reopened.services.isEmpty)
        }
    }

    @Test @MainActor func metadataHasNoKeyAndEndpointChangesRequireExplicitRebinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("services.json")
        let vault = TestCredentialVault()
        let store = CloudTranscriptionServiceStore(storageURL: url, vault: vault, autoLoad: false)
        var service = CloudTranscriptionServiceConfig(name: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!, modelID: "whisper-large-v3-turbo")
        try await store.addOrUpdate(service, apiKey: "test-only-key")
        let frozen = try service.settings()
        #expect(try await store.apiKey(for: frozen) == "test-only-key")
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("test-only-key"))
        let reopened = CloudTranscriptionServiceStore(storageURL: url, vault: vault, autoLoad: false)
        await reopened.load()
        #expect(reopened.errorMessage == nil)
        #expect(reopened.services == [service])
        service.modelID = "custom-asr-model"
        try await store.addOrUpdate(service, apiKey: "test-only-key")
        #expect(frozen.modelID == "whisper-large-v3-turbo")
        #expect(try await store.apiKey(for: frozen) == "test-only-key")
        service.baseURL = URL(string: "https://other.example/v1")!
        try await store.addOrUpdate(service, apiKey: "new-key")
        await #expect(throws: CloudTranscriptionError.changedEndpoint) { try await store.apiKey(for: frozen) }
        let task = ProcessingTask(parameters: .init(transcription: frozen, translation: nil))
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task)).parameters.transcription == frozen)
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
