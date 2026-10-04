import AVFoundation
import CoreML
import Foundation
import Synchronization
import Testing
import VoxlineCore
import WhisperKit
@testable import VoxlineWhisperKit

@Suite("Whisper transcription evidence and boundaries", .serialized)
struct TranscriptionProviderTests {
    @Test func readsFractionalTailAndRejectsInconsistentDuration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tail.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_882_768))
        buffer.frameLength = buffer.frameCapacity
        let data = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { data[index] = index == Int(buffer.frameLength) - 1 ? 0.75 : 0.25 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let audio = try TranscriptionAudio(localURL: url, sourceStartMilliseconds: 960_000, durationMilliseconds: 117_673)
        let samples = try WhisperModelStore.readPCMSamples(audio)
        #expect(samples.count == 1_882_768)
        #expect(samples.first == 0.25 && samples.last == 0.75)
        let inconsistent = try TranscriptionAudio(localURL: url, sourceStartMilliseconds: 0, durationMilliseconds: 117_674)
        #expect(throws: WhisperTranscriptionError.invalidAudio) { try WhisperModelStore.readPCMSamples(inconsistent) }
    }

    @Test func usesRealFramesBeforeAlignmentAndKeepsRows() throws {
        let weights = try MLMultiArray(shape: [2, 1500], dataType: .float16)
        for row in 0..<2 {
            for column in 0..<1500 { weights[[row, column] as [NSNumber]] = NSNumber(value: row * 1500 + column) }
        }
        let cropped = try TranscriptionEvidenceSeeker.validAudioColumns(weights, frameCount: 344_000)
        #expect(cropped.shape == [2, 1075])
        #expect(cropped[[1, 1074] as [NSNumber]] == weights[[1, 1074] as [NSNumber]])
        #expect(throws: (any Error).self) { try TranscriptionEvidenceSeeker.validAudioColumns(weights, frameCount: 1) }
        let floatWeights = try MLMultiArray(shape: [2, 1500], dataType: .float32)
        #expect(throws: (any Error).self) { try TranscriptionEvidenceSeeker.validAudioColumns(floatWeights, frameCount: 16000) }
    }

    @Test func alignmentPathUsesLogicalRowsWithIOSurfacePadding() throws {
        let columns = 1497
        let pixelBuffer = try #require(MLMultiArray.pixelBuffer(for: [4, NSNumber(value: columns)]))
        let padded = MLMultiArray(pixelBuffer: pixelBuffer, shape: [4, NSNumber(value: columns)])
        #expect(padded.strides[0].intValue > columns)
        let dense = try MLMultiArray(shape: [4, NSNumber(value: columns)], dataType: .float16)
        for row in 0..<4 {
            for column in 0..<columns {
                let value = NSNumber(value: abs(column - [0, 1168, 1276, 1496][row]) < 4 ? 1 : 0)
                padded[[row, column] as [NSNumber]] = value
                dense[[row, column] as [NSNumber]] = value
            }
        }
        let path = try WordTimestampAligner.dynamicTimeWarping(padded, tokenCount: 4)
        let expected = try WordTimestampAligner.dynamicTimeWarping(dense, tokenCount: 4)
        #expect(path.map(\.token) == expected.map(\.token))
        #expect(path.map(\.column) == expected.map(\.column))
        #expect(path.first?.token == 0 && path.first?.column == 0)
        #expect(path.last?.token == 3 && path.last?.column == columns - 1)
        #expect(throws: (any Error).self) { try WordTimestampAligner.dynamicTimeWarping(padded, tokenCount: 5) }
        dense[[1, 100] as [NSNumber]] = NSNumber(value: Double.nan)
        #expect(throws: (any Error).self) { try WordTimestampAligner.dynamicTimeWarping(dense, tokenCount: 4) }
    }

    @Test func preservesAbsoluteTextAndConfidenceAndRejectsDroppedCollapsedText() throws {
        let segment = TranscriptionSegment(start: 1, end: 2, text: " hello", avgLogprob: -0.2, noSpeechProb: 0.01,
            words: [WordTiming(word: " hello", tokens: [42], start: 1, end: 2, probability: 0.9)])
        let raw = TranscriptionEvidenceSeeker.raw(segment, offset: 122.25)
        #expect(raw.startSeconds == 123.25 && raw.endSeconds == 124.25)
        #expect(raw.words?.first?.text == " hello")
        #expect(raw.words?.first?.startSeconds == 123.25)
        #expect(raw.averageLogProbability == Double(Float(-0.2)))
        let window = TranscriptionWindowEvidence(seekFrame: 0, frameCount: 48_000, decodedText: " hello",
            decodedTokens: [42], language: "en", skippedAsNoSpeech: false, segmentsBeforeAlignment: [raw], alignedSegments: [raw])
        let result = try TranscriptionEvidenceSeeker.validatedSegments(windows: [window], sourceOffsetSeconds: 122.25,
            frameCount: 48_000, returnedSegments: [raw])
        #expect(result == [raw])
        let collapsed = RawTranscriptionSegment(startSeconds: 124, endSeconds: 124, text: "keep this text", words: nil)
        let invalid = TranscriptionWindowEvidence(seekFrame: 0, frameCount: 48_000, decodedText: collapsed.text,
            decodedTokens: [43], language: "en", skippedAsNoSpeech: false,
            segmentsBeforeAlignment: [collapsed], alignedSegments: [collapsed])
        #expect(throws: (any Error).self) {
            try TranscriptionEvidenceSeeker.validatedSegments(windows: [invalid], sourceOffsetSeconds: 122.25,
                frameCount: 48_000, returnedSegments: [])
        }
        #expect(invalid.alignedSegments?.first?.text == "keep this text")
    }

    @Test func rejectsMissingWindowsDuplicatesAndInvalidWordEvidence() throws {
        let raw = RawTranscriptionSegment(startSeconds: 1, endSeconds: 2, text: "hello", words: nil)
        let first = TranscriptionWindowEvidence(seekFrame: 0, frameCount: 480_000, decodedText: "hello", decodedTokens: [42],
            language: "en", skippedAsNoSpeech: false, segmentsBeforeAlignment: [raw])
        let silent = TranscriptionWindowEvidence(seekFrame: 480_000, frameCount: 160_000, decodedText: "", decodedTokens: [],
            language: "en", skippedAsNoSpeech: true, segmentsBeforeAlignment: [])
        #expect(try TranscriptionEvidenceSeeker.validatedSegments(windows: [first, silent], sourceOffsetSeconds: 0,
            frameCount: 640_000, returnedSegments: [raw]) == [raw])
        #expect(throws: (any Error).self) {
            try TranscriptionEvidenceSeeker.validatedSegments(windows: [first], sourceOffsetSeconds: 0,
                frameCount: 640_000, returnedSegments: [raw])
        }
        #expect(throws: (any Error).self) {
            try TranscriptionEvidenceSeeker.validatedSegments(windows: [first, first], sourceOffsetSeconds: 0,
                frameCount: 480_000, returnedSegments: [raw, raw])
        }
        let invalidWord = RawTranscriptionSegment(startSeconds: 1, endSeconds: 2, text: "hello",
            words: [RawWordTiming(text: "hello", startSeconds: 1, endSeconds: 4, probability: 0.9)])
        #expect(throws: (any Error).self) { try TranscriptionEvidenceSeeker.validate([invalidWord], lower: 0, upper: 3) }
        let unordered = RawTranscriptionSegment(startSeconds: 1.5, endSeconds: 2.5, text: "again", words: nil)
        #expect(throws: (any Error).self) { try TranscriptionEvidenceSeeker.validate([raw, unordered], lower: 0, upper: 3) }
    }

    @Test func rejectsUnknownLanguageAndModelWithoutSubstitution() throws {
        #expect(throws: WhisperTranscriptionError.unsupportedLanguage("english")) {
            try WhisperKitTranscriptionProvider(settings: TranscriptionSettings(modelID: TranscriptionSettings.whisperKitBaseline.modelID,
                languageMode: .specified, languageCode: "english"))
        }
        #expect(throws: WhisperModelError.unknownModel) {
            try WhisperKitTranscriptionProvider(settings: TranscriptionSettings(modelID: "unknown"))
        }
        _ = try WhisperKitTranscriptionProvider(settings: TranscriptionSettings(modelID: TranscriptionSettings.whisperKitBaseline.modelID,
            languageMode: .specified, languageCode: "en"))
    }

    @Test func invalidInputAndCancellationKeepFailureRangeAndStorageErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try TranscriptionAudio(localURL: directory.appendingPathComponent("missing.wav"),
            sourceStartMilliseconds: 120_000, durationMilliseconds: 3000)
        let root = directory.appendingPathComponent("evidence")
        let provider = try WhisperKitTranscriptionProvider(settings: .whisperKitBaseline,
            store: WhisperModelStore(directory: directory.appendingPathComponent("models")), evidenceDirectory: root)
        do {
            _ = try await provider.transcribe(audio: audio)
            Issue.record("Missing PCM returned success")
        } catch let error as TranscriptionFailure {
            #expect(error.evidence.outcome == .failed)
            #expect(error.evidence.sourceStartMilliseconds == 120_000)
            #expect(error.evidence.durationMilliseconds == 3000)
            let url = try #require(error.evidenceURL)
            let saved = try JSONDecoder().decode(TranscriptionEvidence.self, from: Data(contentsOf: url))
            #expect(saved.failureReason == error.evidence.failureReason)
        }
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.transcribe(audio: audio)
        }
        do { _ = try await operation.value; Issue.record("Cancelled transcription returned success") }
        catch let error as TranscriptionFailure {
            #expect(error.isCancelled)
            #expect(error.evidenceURL != nil)
        }
        let blocked = directory.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blocked)
        let blockedProvider = try WhisperKitTranscriptionProvider(settings: .whisperKitBaseline, evidenceDirectory: blocked)
        do { _ = try await blockedProvider.transcribe(audio: audio); Issue.record("Evidence storage failed silently") }
        catch let error as TranscriptionFailure {
            #expect(error.storageError != nil)
            #expect(error.evidenceURL == nil)
            #expect(error.evidence.sourceStartMilliseconds == 120_000)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_MODEL_DIRECTORY"] != nil))
    func realSampleProvider() async throws {
        let environment = ProcessInfo.processInfo.environment
        let models = try #require(environment["VOXLINE_MODEL_DIRECTORY"])
        let chunkRoot = try #require(environment["VOXLINE_PCM_DIRECTORY"])
        let root = URL(fileURLWithPath: "tmp/provider-validation", isDirectory: true)
        let store = WhisperModelStore(directory: URL(fileURLWithPath: models))
        let settings = TranscriptionSettings(modelID: TranscriptionSettings.whisperKitBaseline.modelID,
            languageMode: .specified, languageCode: "en")
        let states = Mutex<[String]>([])
        let provider = try WhisperKitTranscriptionProvider(settings: settings, store: store, evidenceDirectory: root) { progress in
            states.withLock {
                switch progress {
                case .readingAudio: $0.append("reading")
                case .loadingModel: $0.append("loading")
                case .detectingLanguage: $0.append("detecting")
                case .decoding: if $0.last != "decoding" { $0.append("decoding") }
                case .completed: $0.append("completed")
                }
            }
        }
        var results = [TranscriptionEvidence]()
        var failures = [TranscriptionEvidence]()
        for index in 0..<9 {
            let audio = try TranscriptionAudio(localURL: URL(fileURLWithPath: chunkRoot).appendingPathComponent(String(format: "%06d.wav", index)),
                sourceStartMilliseconds: Int64(index * 120_000), durationMilliseconds: index == 8 ? 117_673 : 120_000)
            do {
                let evidence = try await provider.transcribeEvidence(audio: audio)
                results.append(evidence)
                print("S001_PROVIDER chunk=\(index) windows=\(evidence.windows.count) segments=\(evidence.segments.count)")
            } catch let failure as TranscriptionFailure {
                print("S001_PROVIDER_FAILED chunk=\(index) reason=\(failure.localizedDescription) evidence=\(failure.evidenceURL?.path ?? "missing")")
                guard case .invalidAlignment = failure.cause as? WhisperTranscriptionError else { throw failure }
                #expect(failure.evidence.outcome == .failed)
                #expect(failure.storageError == nil)
                let url = try #require(failure.evidenceURL)
                let saved = try JSONDecoder().decode(TranscriptionEvidence.self, from: Data(contentsOf: url))
                #expect(saved.sourceStartMilliseconds == audio.sourceStartMilliseconds)
                #expect(!saved.windows.isEmpty)
                #expect(!saved.segments.isEmpty)
                #expect(saved.failureReason == failure.evidence.failureReason)
                failures.append(saved)
            }
        }
        #expect(results.count + failures.count == 9)
        #expect(!results.isEmpty)
        print("S001_PROVIDER_SUMMARY completed=\(results.count) failed=\(failures.count)")
        #expect(states.withLock { $0.filter { $0 == "loading" }.count } == 1)
        #expect(states.withLock { $0.filter { $0 == "completed" }.count } == results.count)
        let raw = results.flatMap(\.segments)
        try TranscriptionEvidenceSeeker.validate(raw, lower: 0, upper: 1077.673)
        #expect(!raw.isEmpty)
        #expect(raw.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.allSatisfy { $0.words != nil })
        let inventory = try await store.inventory(modelID: settings.modelID)
        guard case .loaded = inventory.state else { Issue.record("Model not reused"); return }
        try await store.unload(modelID: settings.modelID)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_MODEL_DIRECTORY"] != nil))
    func realProviderLanguageAndCancellation() async throws {
        let environment = ProcessInfo.processInfo.environment
        let models = try #require(environment["VOXLINE_MODEL_DIRECTORY"])
        let chunkRoot = try #require(environment["VOXLINE_PCM_DIRECTORY"])
        let root = URL(fileURLWithPath: "tmp/provider-validation", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WhisperModelStore(directory: URL(fileURLWithPath: models))
        let settings = TranscriptionSettings(modelID: TranscriptionSettings.whisperKitBaseline.modelID,
            languageMode: .specified, languageCode: "en")
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: chunkRoot).appendingPathComponent("000000.wav"))
        let head = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 480_000))
        let firstAudio = try TranscriptionAudio(localURL: source.url, sourceStartMilliseconds: 0, durationMilliseconds: 120_000)
        let firstSamples = try WhisperModelStore.readPCMSamples(firstAudio)
        head.frameLength = 480_000
        let headSamples = try #require(head.floatChannelData?[0])
        for index in 0..<480_000 { headSamples[index] = firstSamples[index] }
        let headURL = root.appendingPathComponent("head-30s.wav")
        do {
            let output = try AVAudioFile(forWriting: headURL, settings: source.processingFormat.settings)
            try output.write(from: head)
        }
        let automatic = try WhisperKitTranscriptionProvider(settings: .whisperKitBaseline, store: store, evidenceDirectory: root)
        let headAudio = try TranscriptionAudio(localURL: headURL, sourceStartMilliseconds: 0, durationMilliseconds: 30_000)
        let automaticResult = try await automatic.transcribeEvidence(audio: headAudio)
        #expect(automaticResult.windows.allSatisfy { $0.language == "en" })
        #expect(!automaticResult.segments.isEmpty)
        print("S001_PROVIDER_AUTOMATIC language=en windows=\(automaticResult.windows.count)")

        let mutation = Mutex<Task<Void, Never>?>(nil)
        let activeOperation = Mutex<Task<[RawTranscriptionSegment], any Error>?>(nil)
        let cancelledProvider = try WhisperKitTranscriptionProvider(settings: settings, store: store, evidenceDirectory: root) { progress in
            if case .decoding(let count) = progress, count > 6 {
                mutation.withLock { operation in
                    if operation == nil {
                        operation = Task {
                            await #expect(throws: WhisperTranscriptionError.busy) { try await store.unload(modelID: settings.modelID) }
                        }
                    }
                }
                activeOperation.withLock { $0 }?.cancel()
            }
        }
        do {
            let operation = Task { try await cancelledProvider.transcribe(audio: headAudio) }
            activeOperation.withLock { $0 = operation }
            _ = try await operation.value
            Issue.record("Cancellation during actual decoding returned success")
        } catch let failure as TranscriptionFailure {
            #expect(failure.isCancelled)
            #expect(failure.evidenceURL != nil)
            #expect(failure.evidence.partialDecodedText != nil || !failure.evidence.windows.isEmpty)
            #expect(!(failure.evidence.partialDecodedTokens ?? []).isEmpty || !failure.evidence.windows.isEmpty)
            print("S001_PROVIDER_CANCELLED partialTokens=\(failure.evidence.partialDecodedTokens?.count ?? 0)")
        }
        if let operation = mutation.withLock({ $0 }) { await operation.value }
        else { Issue.record("Actual decoding callback did not run") }
        try await store.unload(modelID: settings.modelID)
        let unloaded = try await store.inventory(modelID: settings.modelID)
        guard case .installed = unloaded.state else { Issue.record("Unload failed"); return }
    }
}
