import Foundation
import Testing
import VoxlineCore
import VoxlineMedia
import VoxlineWhisperKit
@testable import VoxlineApp

@Suite("Sequential task execution", .serialized)
@MainActor
struct TaskProcessingQueueTests {
    private func fixture(count: Int = 2) throws -> (URL, TaskLibrary, ProcessingTask) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = TaskLibrary(tasksDirectory: directory)
        let media = try MediaIdentity(fileName: "fixture.wav", byteCount: 42, sha256: String(repeating: "a", count: 64),
            durationMilliseconds: 4000, audioTrackID: 1)
        let task = ProcessingTask(items: (0..<count).map { index in
            .init(title: "Item \(index)", kind: .audio, source: .localFile(fileName: media.fileName), media: media)
        })
        try library.save(task)
        return (directory, library, task)
    }

    @Test func failuresContinueInOrderAndRetrySkipsCommittedChunksAndKeepsEdits() async throws {
        let (directory, library, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ControlledPipeline(failFirstChunkOf: task.items[0].id)
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline)
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        let processed = try #require(library.task(for: task.id))
        #expect(processed.status == .partiallyFailed)
        #expect(processed.items[1].status == .completed)
        #expect(processed.items[0].checkpoint?.chunks[0].isCompleted == false)
        #expect(processed.items[0].checkpoint?.chunks[1].isCompleted == true)
        #expect(queue.errorMessage == nil)
        #expect(await pipeline.events == ["extract:\(task.items[0].id)", "decode:\(task.items[0].id):0",
            "decode:\(task.items[0].id):2000", "extract:\(task.items[1].id)",
            "decode:\(task.items[1].id):0", "decode:\(task.items[1].id):2000"])
        var edited = processed
        try edited.items[0].cues[0].replaceSourceText(with: "Manual correction")
        try library.save(edited)
        let unchanged = edited.items[1]
        try queue.start(taskID: task.id, mediaID: task.items[0].id)
        await queue.waitUntilIdle()
        let saved = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        #expect(saved.status == .completed)
        #expect(saved.items[0].cues.count == 2)
        #expect(saved.items[0].cues[1].sourceText == "Manual correction")
        #expect(saved.items[1] == unchanged)
        #expect(await pipeline.events.suffix(2) == ["extract:\(task.items[0].id)", "decode:\(task.items[0].id):0"])
        #expect(throws: QueueError.noWork) { try queue.start(taskID: task.id) }
    }

    @Test func itemCancellationWaitsForOldInferenceAndContinuesOtherMedia() async throws {
        let (directory, library, task) = try fixture(count: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ControlledPipeline(holdFirstDecode: true)
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline)
        try queue.start(taskID: task.id)
        await pipeline.waitForHeldDecode()
        try queue.cancel(mediaID: task.items[0].id)
        try queue.cancel(mediaID: task.items[2].id)
        #expect(queue.isCancelling)
        #expect(throws: QueueError.busy) { try queue.start(taskID: task.id, mediaID: task.items[0].id) }
        // This operation deliberately ignores cancellation until released, like a late SDK callback.
        await pipeline.releaseDecode()
        await queue.waitUntilIdle()
        let cancelled = try #require(library.task(for: task.id))
        #expect(cancelled.items[0].status == .cancelled)
        #expect(cancelled.items[0].cues.isEmpty)
        #expect(cancelled.items[1].status == .completed)
        #expect(cancelled.items[2].status == .cancelled)
        #expect(await !pipeline.events.contains("extract:\(task.items[2].id)"))
        if case .cancelled(let evidence) = cancelled.items[0].checkpoint?.chunks[0].state {
            #expect(evidence?.segments.first?.text == "Keep.")
        } else { Issue.record("Cancelled evidence missing") }
        try queue.start(taskID: task.id, mediaID: task.items[0].id)
        await queue.waitUntilIdle()
        #expect(library.task(for: task.id)?.items[0].status == .completed)
    }

    @Test func taskCancellationStopsWaitingMediaAndCanResume() async throws {
        let (directory, library, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ControlledPipeline(holdFirstDecode: true)
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline)
        try queue.start(taskID: task.id)
        await pipeline.waitForHeldDecode()
        try queue.cancel()
        await pipeline.releaseDecode()
        await queue.waitUntilIdle()
        #expect(library.task(for: task.id)?.items.allSatisfy { $0.status == .cancelled } == true)
        #expect(await !pipeline.events.contains("extract:\(task.items[1].id)"))
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        #expect(library.task(for: task.id)?.status == .completed)
    }

    @Test func writeFailureStopsSchedulingAndPreservesLatestUnsavedEdits() async throws {
        let (directory, library, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ControlledPipeline(holdStartMilliseconds: 2000)
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline)
        try queue.start(taskID: task.id)
        await pipeline.waitForHeldDecode()
        let originalURL = library.defaultURL(for: task.id)
        let originalData = try Data(contentsOf: originalURL)
        var edited = try #require(library.task(for: task.id))
        try edited.items[0].cues[0].replaceSourceText(with: "Unsaved correction")
        let blockedURL = directory.appendingPathComponent("occupied.voxline")
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: false)
        library.register(edited, at: blockedURL)
        await pipeline.releaseDecode()
        await queue.waitUntilIdle()
        #expect(queue.errorMessage != nil)
        let interrupted = try #require(library.task(for: task.id))
        #expect(interrupted.items[0].status == .interrupted(stage: .transcription))
        #expect(interrupted.items[0].cues.count == 1)
        #expect(interrupted.items[0].cues[0].sourceText == "Unsaved correction")
        #expect(try Data(contentsOf: originalURL) == originalData)
        #expect(await !pipeline.events.contains("extract:\(task.items[1].id)"))
        library.register(interrupted, at: originalURL)
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        #expect(library.task(for: task.id)?.status == .completed)
        #expect(library.task(for: task.id)?.items[0].cues[0].sourceText == "Unsaved correction")
    }

    @Test func incompatibleRangesFailOnlyTheirMediaAndTranslationIsExplicitlyUnavailable() async throws {
        let (directory, library, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = initial
        try task.freezeParameters()
        try task.items[0].initializeCheckpoint(parameters: task.parameters,
            ranges: [.init(sourceStartMilliseconds: 0, durationMilliseconds: 4000)])
        task.items[0].status = .interrupted(stage: .transcription)
        try library.save(task)
        let queue = TaskProcessingQueue(library: library, pipeline: ControlledPipeline())
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        #expect(library.task(for: task.id)?.items[0].status == .failed(reason: CheckpointError.incompatibleContext.localizedDescription))
        #expect(library.task(for: task.id)?.items[1].status == .completed)
        var configured = ProcessingTask(items: initial.items)
        var parameters = configured.parameters
        parameters.translation = try TranslationSettings(baseURL: URL(string: "https://example.com/v1")!, modelID: "test", targetLanguage: "zh", serviceID: UUID())
        try configured.updateParameters(parameters)
        try library.save(configured)
        #expect(throws: (any Error).self) { try queue.start(taskID: configured.id) }
        #expect(library.task(for: configured.id)?.startedAt == nil)
    }

    @Test func manualTimingConflictKeepsEditAndRawEvidenceWhileOtherMediaContinue() async throws {
        let (directory, library, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ControlledPipeline(holdStartMilliseconds: 2000)
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline)
        try queue.start(taskID: task.id)
        await pipeline.waitForHeldDecode()
        var edited = try #require(library.task(for: task.id))
        edited.items[0].cues[0].endMilliseconds = 2500
        try library.save(edited)
        await pipeline.releaseDecode()
        await queue.waitUntilIdle()
        let result = try #require(library.task(for: task.id))
        #expect(result.status == .partiallyFailed)
        #expect(result.items[0].cues[0].endMilliseconds == 2500)
        #expect(result.items[1].status == .completed)
        if case .failed(_, let evidence) = result.items[0].checkpoint?.chunks[1].state {
            #expect(evidence?.segments.first?.text == "Keep.")
        } else { Issue.record("Timing conflict did not preserve the failed range") }
        #expect(queue.errorMessage == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_QUEUE_MEDIA"] != nil))
    func nativeMediaAndWhisperPipelinePersistsRealBatchResults() async throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(environment["VOXLINE_QUEUE_MEDIA"]))
        let models = URL(fileURLWithPath: try #require(environment["VOXLINE_MODEL_DIRECTORY"]))
        let directory = URL(fileURLWithPath: "tmp/queue-validation/\(UUID().uuidString)", isDirectory: true)
        let library = TaskLibrary(tasksDirectory: directory.appendingPathComponent("tasks"))
        let bookmarks = LocalMediaStore(directory: directory.appendingPathComponent("bookmarks"))
        let inspection = try await MediaInspector.shared.inspect(source)
        let track = try #require(inspection.audioTracks.first { $0.isDecodable })
        let identity = try inspection.identity(audioTrackID: track.id)
        let parameters = TaskParameters(transcription: TranscriptionSettings(modelID: TranscriptionSettings.whisperKitBaseline.modelID,
            languageMode: .specified, languageCode: "en"))
        let task = ProcessingTask(title: "Native queue validation", items: (1...2).map {
            .init(title: "Native \($0)", kind: .audio, source: .localFile(fileName: identity.fileName), media: identity)
        }, parameters: parameters)
        for item in task.items { try await bookmarks.save(projectID: item.id, identity: identity, url: source) }
        try library.save(task)
        let pipeline = LocalMediaTranscriptionPipeline(mediaStore: bookmarks,
            extractor: AudioExtractor(directory: directory.appendingPathComponent("audio")),
            modelStore: WhisperModelStore(directory: models))
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline)
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        #expect(queue.errorMessage == nil)
        let reopened = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        #expect(reopened.status == .completed)
        #expect(reopened.items.allSatisfy { !$0.cues.isEmpty && $0.checkpoint?.chunks.allSatisfy(\.isCompleted) == true })
        let preserved = reopened.items
        #expect(throws: QueueError.noWork) { try queue.start(taskID: task.id) }
        #expect(library.task(for: task.id)?.items == preserved)
        print("Native queue: \(reopened.completedCount) media, \(reopened.items.reduce(0) { $0 + $1.cues.count }) cues; \(library.defaultURL(for: task.id).path)")
    }
}

/// Test-only deterministic boundary; the product singleton always uses the local native pipeline.
private actor ControlledPipeline: MediaTranscriptionPipeline {
    private var failingMedia: UUID?
    private var holdStart: Int64?
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var events: [String] = []

    init(failFirstChunkOf: UUID? = nil, holdFirstDecode: Bool = false, holdStartMilliseconds: Int64? = nil) {
        failingMedia = failFirstChunkOf
        holdStart = holdFirstDecode ? 0 : holdStartMilliseconds
    }

    func waitForHeldDecode() async {
        if held != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func releaseDecode() {
        held?.resume()
        held = nil
    }

    func extract(item: TaskMediaItem, progress: @escaping @Sendable (AudioExtractionProgress) -> Void) async throws -> [TranscriptionAudio] {
        events.append("extract:\(item.id)")
        return try [0, 2000].map { start in
            try TranscriptionAudio(localURL: URL(fileURLWithPath: "/tmp/\(item.id).wav"),
                sourceStartMilliseconds: Int64(start), durationMilliseconds: 2000)
        }
    }

    func transcribe(audio: TranscriptionAudio, settings: TranscriptionSettings,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionEvidence {
        let id = audio.localURL.deletingPathExtension().lastPathComponent
        events.append("decode:\(id):\(audio.sourceStartMilliseconds)")
        if holdStart == audio.sourceStartMilliseconds {
            holdStart = nil
            await withCheckedContinuation { continuation in
                held = continuation
                observer?.resume()
                observer = nil
            }
        }
        var evidence = TranscriptionEvidence(settings: settings, audio: audio)
        let start = Double(audio.sourceStartMilliseconds) / 1000
        evidence.segments = [.init(startSeconds: start, endSeconds: start + 0.5, text: "Keep.", words: nil)]
        evidence.outcome = .completed
        if failingMedia?.uuidString == id && audio.sourceStartMilliseconds == 0 {
            failingMedia = nil
            evidence.outcome = .failed
            evidence.failureReason = "Test alignment failure"
            throw TranscriptionFailure(cause: QueueError.unavailable("Test alignment failure"), evidence: evidence, evidenceURL: nil)
        }
        return evidence
    }
}
