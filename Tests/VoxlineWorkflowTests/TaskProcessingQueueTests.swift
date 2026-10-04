import Foundation
import Testing
import VoxlineCore
import VoxlineMedia
import VoxlineWhisperKit
import VoxlineTranslation
@testable import VoxlineWorkflow

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
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline, translationPipeline: TranslationNotExpected())
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        let processed = try #require(library.task(for: task.id))
        #expect(processed.status == .partiallyFailed)
        #expect(processed.items[1].status == .completed)
        #expect(processed.items[0].checkpoint?.chunks[0].isCompleted == false)
        let failedTranscription = processed.items[0]
        #expect(failedTranscription.extractionState == .completed)
        #expect(failedTranscription.transcriptionState == .failed)
        #expect(failedTranscription.translationState == .waiting)
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
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline, translationPipeline: TranslationNotExpected())
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
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline, translationPipeline: TranslationNotExpected())
        try queue.start(taskID: task.id)
        await pipeline.waitForHeldDecode()
        try queue.cancel()
        await pipeline.releaseDecode()
        await queue.waitUntilIdle()
        #expect(library.task(for: task.id)?.items.allSatisfy { $0.status == .cancelled } == true)
        #expect(await !pipeline.events.contains("extract:\(task.items[1].id)"))
        let reopenedLibrary = TaskLibrary(tasksDirectory: directory)
        #expect(reopenedLibrary.task(for: task.id)?.items.allSatisfy { $0.status == .cancelled } == true)
        let resumedQueue = TaskProcessingQueue(library: reopenedLibrary, pipeline: pipeline, translationPipeline: TranslationNotExpected())
        try resumedQueue.start(taskID: task.id)
        await resumedQueue.waitUntilIdle()
        #expect(reopenedLibrary.task(for: task.id)?.status == .completed)
    }

    @Test func writeFailureStopsSchedulingAndPreservesLatestUnsavedEdits() async throws {
        let (directory, library, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ControlledPipeline(holdStartMilliseconds: 2000)
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline, translationPipeline: TranslationNotExpected())
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

    @Test func incompatibleRangesFailOnlyTheirMediaAndMissingTranslationServiceIsExplicit() async throws {
        let (directory, library, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = initial
        try task.freezeParameters()
        try task.items[0].initializeCheckpoint(parameters: task.parameters,
            ranges: [.init(sourceStartMilliseconds: 0, durationMilliseconds: 4000)])
        task.items[0].status = .interrupted(stage: .transcription)
        try library.save(task)
        let queue = TaskProcessingQueue(library: library, pipeline: ControlledPipeline(), translationPipeline: UnavailableServicePipeline())
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        #expect(library.task(for: task.id)?.items[0].status == .failed(reason: CheckpointError.incompatibleContext.localizedDescription))
        #expect(library.task(for: task.id)?.items[1].status == .completed)
        var configured = ProcessingTask(items: initial.items)
        var parameters = configured.parameters
        parameters.translation = try TranslationSettings(baseURL: URL(string: "https://example.com/v1")!, modelID: "test", targetLanguage: "zh", serviceID: UUID())
        try configured.updateParameters(parameters)
        try library.save(configured)
        try queue.start(taskID: configured.id)
        await queue.waitUntilIdle()
        #expect(library.task(for: configured.id)?.items.allSatisfy { $0.status == .failed(reason: TranslationServiceError.unknownService.localizedDescription) } == true)
    }

    @Test func manualTimingConflictKeepsEditAndRawEvidenceWhileOtherMediaContinue() async throws {
        let (directory, library, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ControlledPipeline(holdStartMilliseconds: 2000)
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline, translationPipeline: TranslationNotExpected())
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

    @Test func normalTranslationAndRetranslationUsePersistedCountAndPrompt() async throws {
        let (directory, library, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = initial
        var parameters = task.parameters
        let settings = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!, modelID: "frozen-model",
            targetLanguage: "zh", serviceID: UUID(), batchSize: 1, systemPrompt: "保留角色称呼。")
        parameters.translation = settings
        try task.updateParameters(parameters)
        try library.save(task)
        let transcription = ControlledPipeline()
        let translation = ControlledTranslationPipeline()
        let queue = TaskProcessingQueue(library: library, pipeline: transcription, translationPipeline: translation)
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        let completed = try #require(library.task(for: task.id))
        #expect(completed.status == .completed)
        #expect(await translation.requests.map(\.count) == [1, 1, 1, 1])
        #expect(completed.items.allSatisfy { $0.checkpoint?.parameters.translation == settings })
        let reopened = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        #expect(reopened.parameters.translation == settings)
        let previousEvents = await transcription.events
        try queue.startRetranslation(taskID: task.id, mediaID: completed.items[0].id,
            cueIDs: completed.items[0].cues.map(\.id), replacingExistingTranslations: true)
        await queue.waitUntilIdle()
        #expect(await translation.requests.map(\.count) == [1, 1, 1, 1, 1, 1])
        #expect(await translation.settingsUsed.allSatisfy { $0 == settings })
        #expect(await transcription.events == previousEvents)
    }

    @Test func transientFailuresPauseAfterThreeRetriesAndResumeWithoutTranscription() async throws {
        let (directory, library, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = initial
        var parameters = task.parameters
        parameters.translation = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!,
            modelID: "frozen-model", targetLanguage: "zh-Hans", serviceID: UUID())
        try task.updateParameters(parameters)
        try library.save(task)
        let transcription = ControlledPipeline(cuesPerChunk: 16)
        let unavailable = SubtitleTranslationError.temporarilyUnavailable(statusCode: 503, retryAfter: nil)
        let translation = ControlledTranslationPipeline(errors: [2: unavailable, 3: unavailable, 4: unavailable, 5: unavailable])
        let waits = RetrySleepRecorder()
        let queue = TaskProcessingQueue(library: library, pipeline: transcription, translationPipeline: translation,
            retrySleep: { await waits.record($0) }, retryJitter: { 0 })
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        #expect(await waits.durations == [.seconds(5), .seconds(15), .seconds(45)])
        let paused = try #require(library.task(for: task.id))
        #expect(paused.status == .translationPaused)
        #expect(paused.items[0].status.isTranslationPaused)
        #expect(paused.items[1].status == .completed)
        #expect(paused.items[0].checkpoint?.translationBatches.map(\.isCompleted) == [true, false])
        let badge = paused.items[0]
        #expect(badge.transcriptionState == .completed && badge.translationState == .paused)
        #expect(queue.translationRetryWait == nil)
        let calls = await translation.requests
        #expect(calls.count == 7 && Array(calls[1...4]).allSatisfy { $0 == calls[1] })
        let transcriptionEvents = await transcription.events
        let reopened = TaskLibrary(tasksDirectory: directory)
        try reopened.commitCheckpoint(taskID: task.id) {
            $0.items[0].cues[0].translation = .succeeded(text: "人工译文", sourceRevision: 1)
        }
        let successfulBatch = try #require(paused.items[0].checkpoint?.translationBatches[0])
        let resumed = TaskProcessingQueue(library: reopened, pipeline: transcription, translationPipeline: translation)
        try resumed.start(taskID: task.id, mediaID: task.items[0].id)
        await resumed.waitUntilIdle()
        let completed = try TaskDocumentCodec.decode(Data(contentsOf: reopened.defaultURL(for: task.id)))
        #expect(completed.status == .completed)
        #expect(completed.items[0].cues[0].translation == .succeeded(text: "人工译文", sourceRevision: 1))
        #expect(completed.items[0].checkpoint?.translationBatches[0] == successfulBatch)
        #expect(completed.items[1] == paused.items[1])
        #expect(await translation.requests.last == calls[1])
        #expect(await transcription.events == transcriptionEvents)
    }

    @Test(arguments: [true, false])
    func retryWaitSupportsCancellationAndProtectsEdits(cancel: Bool) async throws {
        let (directory, library, initial) = try fixture(count: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = initial
        var parameters = task.parameters
        parameters.translation = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!,
            modelID: "frozen-model", targetLanguage: "zh-Hans", serviceID: UUID())
        try task.updateParameters(parameters)
        try library.save(task)
        let translation = ControlledTranslationPipeline(errors: [1: .rateLimited(retryAfter: "120")])
        let wait = RetrySleepRecorder(hold: true)
        let queue = TaskProcessingQueue(library: library, pipeline: ControlledPipeline(), translationPipeline: translation,
            retrySleep: { try await wait.sleep($0) }, retryJitter: { 0 })
        try queue.start(taskID: task.id)
        await wait.waitUntilHeld()
        let progress = try #require(queue.translationRetryWait)
        #expect(progress.attempt == 1)
        #expect(progress.label(at: progress.deadline.addingTimeInterval(-30)).contains("30 秒"))
        #expect(queue.progressText?.contains("已译 0／2 句") == true)
        #expect(await wait.durations == [.seconds(120)])
        var reopened = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        reopened.interruptRunningItems()
        #expect(reopened.items[0].status == .interrupted(stage: .translation))
        if cancel {
            try queue.cancel()
            #expect(throws: QueueError.busy) { try queue.start(taskID: task.id) }
        } else {
            try library.commitCheckpoint(taskID: task.id) { try $0.items[0].cues[0].replaceSourceText(with: "人工修正") }
        }
        await wait.release()
        await queue.waitUntilIdle()
        #expect(await translation.requests.count == 1)
        #expect(queue.translationRetryWait == nil)
        let result = try #require(library.task(for: task.id))
        if cancel { #expect(result.items[0].status == .cancelled) }
        else {
            #expect(result.items[0].status == .failed(reason: CheckpointError.editedCue.localizedDescription))
            #expect(result.items[0].cues[0].sourceText == "人工修正")
        }
    }

    @Test func cancellationInterruptsRealRetrySleepImmediately() async throws {
        let (directory, library, initial) = try fixture(count: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = initial
        var parameters = task.parameters
        parameters.translation = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!,
            modelID: "frozen-model", targetLanguage: "zh-Hans", serviceID: UUID())
        try task.updateParameters(parameters)
        try library.save(task)
        let translation = ControlledTranslationPipeline(errors: [1: .rateLimited(retryAfter: "120")])
        let queue = TaskProcessingQueue(library: library, pipeline: ControlledPipeline(), translationPipeline: translation)
        try queue.start(taskID: task.id)
        for _ in 0..<2000 {
            if queue.translationRetryWait != nil { break }
            await Task.yield()
        }
        _ = try #require(queue.translationRetryWait)
        let start = ContinuousClock.now
        try queue.cancel(mediaID: task.items[0].id)
        await queue.waitUntilIdle()
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(library.task(for: task.id)?.items[0].status == .cancelled)
        #expect(await translation.requests.count == 1)
    }

    @Test func transientRetrySucceedsWithSameBatchAndServerDelay() async throws {
        let (directory, library, initial) = try fixture(count: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = initial
        var parameters = task.parameters
        parameters.translation = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!,
            modelID: "frozen-model", targetLanguage: "zh-Hans", serviceID: UUID())
        try task.updateParameters(parameters)
        try library.save(task)
        let translation = ControlledTranslationPipeline(errors: [1: .rateLimited(retryAfter: "10"),
            2: .temporarilyUnavailable(statusCode: 503, retryAfter: nil)])
        let waits = RetrySleepRecorder()
        let queue = TaskProcessingQueue(library: library, pipeline: ControlledPipeline(), translationPipeline: translation,
            retrySleep: { await waits.record($0) }, retryJitter: { 0 })
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        #expect(await waits.durations == [.seconds(10), .seconds(15)])
        #expect(library.task(for: task.id)?.status == .completed)
        #expect(await translation.requests.count == 3)
        #expect(await Set(translation.requests).count == 1)
        #expect(library.task(for: task.id)?.items[0].checkpoint?.translationBatches.count == 1)
    }

    @Test func translationFailureRetriesOnlyUncommittedBatchAndPreservesManualTranslation() async throws {
        let (directory, library, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = initial
        var parameters = task.parameters
        parameters.translation = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!, modelID: "frozen-model", targetLanguage: "zh-Hans", serviceID: UUID())
        try task.updateParameters(parameters)
        try library.save(task)
        let transcription = ControlledPipeline(cuesPerChunk: 16)
        let translation = ControlledTranslationPipeline(failCall: 2)
        let queue = TaskProcessingQueue(library: library, pipeline: transcription, translationPipeline: translation)
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        let processed = try #require(library.task(for: task.id))
        #expect(processed.status == .partiallyFailed)
        #expect(processed.items[0].checkpoint?.translationBatches.map(\.isCompleted) == [true, false])
        let failedTranslation = processed.items[0]
        #expect(failedTranslation.extractionState == .completed)
        #expect(failedTranslation.transcriptionState == .completed)
        #expect(failedTranslation.translationState == .failed)
        #expect(processed.items[1].status == .completed)
        let originalBatchID = try #require(processed.items[0].checkpoint?.translationBatches[1].id)
        let previousCalls = await translation.requests
        #expect(previousCalls.map(\.count) == [30, 2, 30, 2])
        try library.commitCheckpoint(taskID: task.id) { task in
            task.items[0].cues[0].translation = .succeeded(text: "Manual translation", sourceRevision: task.items[0].cues[0].sourceRevision)
        }
        let decodingCalls = await transcription.events.filter { $0.hasPrefix("decode:") }
        try queue.start(taskID: task.id, mediaID: task.items[0].id)
        await queue.waitUntilIdle()
        let completed = try #require(library.task(for: task.id))
        #expect(completed.status == .completed)
        #expect(completed.items[0].cues[0].translation == .succeeded(text: "Manual translation", sourceRevision: 1))
        #expect(completed.items[0].checkpoint?.translationBatches[1].id == originalBatchID)
        #expect(await translation.requests.last == previousCalls[1])
        #expect(await transcription.events.filter { $0.hasPrefix("decode:") } == decodingCalls)
    }

    @Test(arguments: [true, false])
    func translationCancellationAndConcurrentSourceEditProtectCurrentText(cancel: Bool) async throws {
        let (directory, library, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = initial
        var parameters = task.parameters
        parameters.translation = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!, modelID: "frozen-model", targetLanguage: "zh", serviceID: UUID())
        try task.updateParameters(parameters)
        try library.save(task)
        let translation = ControlledTranslationPipeline(holdFirstCall: true)
        let queue = TaskProcessingQueue(library: library, pipeline: ControlledPipeline(), translationPipeline: translation)
        try queue.start(taskID: task.id)
        await translation.waitForRequest()
        if cancel {
            try queue.cancel(mediaID: task.items[0].id)
            #expect(throws: QueueError.busy) { try queue.start(taskID: task.id) }
        } else {
            try library.commitCheckpoint(taskID: task.id) { try $0.items[0].cues[0].replaceSourceText(with: "Current edited source") }
        }
        await translation.releaseRequest()
        await queue.waitUntilIdle()
        let stopped = try #require(library.task(for: task.id))
        #expect(stopped.items[1].status == .completed)
        #expect(stopped.items[0].cues.allSatisfy { $0.translation == .pending })
        let stoppedTranslation = stopped.items[0]
        #expect(stoppedTranslation.extractionState == .completed)
        #expect(stoppedTranslation.transcriptionState == .completed)
        #expect(stoppedTranslation.translationState == (cancel ? .cancelled : .failed))
        if cancel { #expect(stopped.items[0].status == .cancelled) }
        else {
            #expect(stopped.items[0].status == .failed(reason: CheckpointError.editedCue.localizedDescription))
            #expect(stopped.items[0].cues[0].sourceText == "Current edited source")
        }
        try queue.start(taskID: task.id, mediaID: task.items[0].id)
        await queue.waitUntilIdle()
        #expect(library.task(for: task.id)?.status == .completed)
        if !cancel { #expect(library.task(for: task.id)?.items[0].cues[0].sourceText == "Current edited source") }
    }

    @Test func selectedRetranslationRequiresReplacementChoiceAndDoesNotExtractAgain() async throws {
        let (directory, library, task, transcription) = try await translatedFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = task.items[0]
        let selectedID = original.cues[0].id
        try library.commitCheckpoint(taskID: task.id) {
            $0.items[0].cues[0].translation = .succeeded(text: "Manual correction", sourceRevision: 1)
        }
        let translation = ControlledTranslationPipeline()
        let queue = TaskProcessingQueue(library: library, pipeline: transcription, translationPipeline: translation)
        let previousFile = try Data(contentsOf: library.defaultURL(for: task.id))
        #expect(throws: CheckpointError.existingResults) {
            try queue.startRetranslation(taskID: task.id, mediaID: original.id, cueIDs: [selectedID], replacingExistingTranslations: false)
        }
        #expect(try Data(contentsOf: library.defaultURL(for: task.id)) == previousFile)
        let extractionEvents = await transcription.events
        try queue.startRetranslation(taskID: task.id, mediaID: original.id, cueIDs: [selectedID], replacingExistingTranslations: true)
        await queue.waitUntilIdle()
        let saved = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        #expect(saved.status == .completed)
        #expect(await transcription.events == extractionEvents)
        #expect(await translation.requests == [[selectedID]])
        #expect(saved.items[0].checkpoint?.chunks == original.checkpoint?.chunks)
        #expect(saved.items[0].cues[1] == original.cues[1])
        #expect(saved.items[1] == task.items[1])
        #expect(saved.items[0].cues[0].translation == .succeeded(text: "Test-only translation", sourceRevision: 1))
    }

    @Test func ordinaryRetryPreservesOutdatedManualTranslationUntilExplicitReplacement() async throws {
        let (directory, library, task, transcription) = try await translatedFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try library.commitCheckpoint(taskID: task.id) {
            $0.items[0].cues[0].translation = .succeeded(text: "Keep this manual translation", sourceRevision: 1)
            try $0.items[0].cues[0].replaceSourceText(with: "Corrected source")
            $0.items[0].status = .needsReview
        }
        let translation = ControlledTranslationPipeline()
        let queue = TaskProcessingQueue(library: library, pipeline: transcription, translationPipeline: translation)
        try queue.start(taskID: task.id, mediaID: task.items[0].id)
        await queue.waitUntilIdle()
        let saved = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        #expect(saved.items[0].status == .needsReview)
        #expect(saved.items[0].cues[0].translation == .succeeded(text: "Keep this manual translation", sourceRevision: 1))
        #expect(await translation.requests.isEmpty)
        try queue.startRetranslation(taskID: task.id, mediaID: task.items[0].id,
            cueIDs: [task.items[0].cues[0].id], replacingExistingTranslations: true)
        await queue.waitUntilIdle()
        #expect(library.task(for: task.id)?.items[0].cues[0].translation == .succeeded(text: "Test-only translation", sourceRevision: 2))
    }

    @Test(arguments: [true, false])
    func retranslationKeepsLaterEditOrCancelledExistingTranslation(cancel: Bool) async throws {
        let (directory, library, task, transcription) = try await translatedFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let translation = ControlledTranslationPipeline(holdFirstCall: true)
        let queue = TaskProcessingQueue(library: library, pipeline: transcription, translationPipeline: translation)
        let mediaID = task.items[0].id
        let cueID = task.items[0].cues[0].id
        try queue.startRetranslation(taskID: task.id, mediaID: mediaID, cueIDs: [cueID], replacingExistingTranslations: true)
        await translation.waitForRequest()
        if cancel { try queue.cancel(mediaID: mediaID) }
        else {
            try library.commitCheckpoint(taskID: task.id) {
                $0.items[0].cues[0].translation = .succeeded(text: "Later manual correction", sourceRevision: 1)
            }
        }
        #expect(throws: QueueError.busy) {
            try queue.startRetranslation(taskID: task.id, mediaID: mediaID, cueIDs: [cueID], replacingExistingTranslations: true)
        }
        await translation.releaseRequest()
        await queue.waitUntilIdle()
        let saved = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        #expect(saved.items[0].cues[0].translation == (cancel ? task.items[0].cues[0].translation : .succeeded(text: "Later manual correction", sourceRevision: 1)))
        #expect(saved.items[1] == task.items[1])
        #expect(saved.items[0].checkpoint?.chunks == task.items[0].checkpoint?.chunks)
        #expect(saved.items[0].status == (cancel ? .cancelled : .failed(reason: CheckpointError.editedCue.localizedDescription)))
    }

    private func translatedFixture() async throws -> (URL, TaskLibrary, ProcessingTask, ControlledPipeline) {
        let (directory, library, initial) = try fixture()
        var task = initial
        var parameters = task.parameters
        parameters.translation = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!, modelID: "frozen-model", targetLanguage: "zh-Hans", serviceID: UUID())
        try task.updateParameters(parameters)
        try library.save(task)
        let pipeline = ControlledPipeline()
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline, translationPipeline: ControlledTranslationPipeline())
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        return (directory, library, try #require(library.task(for: task.id)), pipeline)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_QUEUE_MEDIA"] != nil &&
                  ProcessInfo.processInfo.environment["VOXLINE_QUEUE_AUDIO"] != nil))
    func nativeMediaAndWhisperPipelinePersistsRealBatchResults() async throws {
        let environment = ProcessInfo.processInfo.environment
        let video = URL(fileURLWithPath: try #require(environment["VOXLINE_QUEUE_MEDIA"]))
        let audio = URL(fileURLWithPath: try #require(environment["VOXLINE_QUEUE_AUDIO"]))
        let models = URL(fileURLWithPath: try #require(environment["VOXLINE_MODEL_DIRECTORY"]))
        let directory = URL(fileURLWithPath: "tmp/queue-validation/\(UUID().uuidString)", isDirectory: true)
        let library = TaskLibrary(tasksDirectory: directory.appendingPathComponent("tasks"))
        let bookmarks = LocalMediaStore(directory: directory.appendingPathComponent("bookmarks"))
        let videoInspection = try await MediaInspector.shared.inspect(video)
        let audioInspection = try await MediaInspector.shared.inspect(audio)
        let videoIdentity = try videoInspection.identity(audioTrackID: #require(videoInspection.audioTracks.first { $0.isDecodable }).id)
        let audioIdentity = try audioInspection.identity(audioTrackID: #require(audioInspection.audioTracks.first { $0.isDecodable }).id)
        let parameters = TaskParameters(transcription: TranscriptionSettings(modelID: TranscriptionSettings.whisperKitBaseline.modelID,
            languageMode: .specified, languageCode: "en"))
        let task = ProcessingTask(title: "Native mixed queue validation", items: [
            .init(title: "Missing bookmark", kind: .video, source: .localFile(fileName: videoIdentity.fileName), media: videoIdentity),
            .init(title: "Native video", kind: .video, source: .localFile(fileName: videoIdentity.fileName), media: videoIdentity),
            .init(title: "Native audio", kind: .audio, source: .localFile(fileName: audioIdentity.fileName), media: audioIdentity)
        ], parameters: parameters)
        try await bookmarks.save(projectID: task.items[1].id, identity: videoIdentity, url: video)
        try await bookmarks.save(projectID: task.items[2].id, identity: audioIdentity, url: audio)
        try library.save(task)
        let pipeline = LocalMediaTranscriptionPipeline(mediaStore: bookmarks,
            extractor: AudioExtractor(directory: directory.appendingPathComponent("audio")),
            modelStore: WhisperModelStore(directory: models))
        let queue = TaskProcessingQueue(library: library, pipeline: pipeline, translationPipeline: TranslationNotExpected())
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        #expect(queue.errorMessage == nil)
        var reopened = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        #expect(reopened.status == .partiallyFailed)
        #expect(reopened.items[0].status == .failed(reason: "找不到本机媒体文件，请在详情中重新关联。"))
        #expect(reopened.items.dropFirst().allSatisfy {
            $0.status == .completed && !$0.cues.isEmpty && $0.checkpoint?.chunks.allSatisfy(\.isCompleted) == true
        })
        #expect(reopened.parameters == parameters)
        #expect(reopened.items.dropFirst().allSatisfy { $0.checkpoint?.parameters == parameters })
        // Paired S001 inputs contain the same six utterances. Codec packet tails
        // must not shift their word alignment by seconds.
        let videoCues = reopened.items[1].cues
        let audioCues = reopened.items[2].cues
        #expect(videoCues.count == 6 && audioCues.count == 6)
        #expect(videoCues.map(\.sourceText) == audioCues.map(\.sourceText))
        #expect(try #require(videoCues.last).startMilliseconds > 28_000)
        for (videoCue, audioCue) in zip(videoCues, audioCues) {
            #expect(abs(videoCue.startMilliseconds - audioCue.startMilliseconds) <= 300)
        }
        try reopened.items[1].cues[0].replaceSourceText(with: "Manual correction after real inference")
        try library.save(reopened)
        let preserved = Array(reopened.items.dropFirst())
        let freshLibrary = TaskLibrary(tasksDirectory: library.tasksDirectory)
        #expect(freshLibrary.task(for: task.id) == reopened)
        try await bookmarks.save(projectID: task.items[0].id, identity: videoIdentity, url: video)
        let retryQueue = TaskProcessingQueue(library: freshLibrary, pipeline: pipeline, translationPipeline: TranslationNotExpected())
        try retryQueue.start(taskID: task.id, mediaID: task.items[0].id)
        await retryQueue.waitUntilIdle()
        let completed = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        #expect(retryQueue.errorMessage == nil)
        #expect(completed.status == .completed)
        #expect(Array(completed.items.dropFirst()) == preserved)
        #expect(throws: QueueError.noWork) { try retryQueue.start(taskID: task.id) }
        for item in completed.items {
            let output = directory.appendingPathComponent("\(item.id).source.srt")
            try SubtitleExporter.export(cues: item.cues, kind: .source, to: output, media: item.media)
            #expect(try String(contentsOf: output, encoding: .utf8) ==
                SubtitleExporter.generateSRT(cues: item.cues, kind: .source, media: item.media))
        }
        print("Native mixed queue: missing bookmark failed, later video/audio completed, reload and repaired retry preserved edits; \(completed.completedCount) media, \(completed.items.reduce(0) { $0 + $1.cues.count }) cues; \(library.defaultURL(for: task.id).path)")
    }
}

/// Test-only deterministic boundary; the product singleton always uses the local native pipeline.
private actor ControlledPipeline: MediaTranscriptionPipeline {
    private var failingMedia: UUID?
    private var holdStart: Int64?
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private let cuesPerChunk: Int
    private(set) var events: [String] = []

    init(failFirstChunkOf: UUID? = nil, holdFirstDecode: Bool = false, holdStartMilliseconds: Int64? = nil, cuesPerChunk: Int = 1) {
        failingMedia = failFirstChunkOf
        holdStart = holdFirstDecode ? 0 : holdStartMilliseconds
        self.cuesPerChunk = cuesPerChunk
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
        evidence.segments = (0..<cuesPerChunk).map { index in
            .init(startSeconds: start + Double(index) * 0.12, endSeconds: start + Double(index) * 0.12 + 0.08, text: "Keep.", words: nil)
        }
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

private actor ControlledTranslationPipeline: SubtitleTranslationPipeline {
    private var failCall: Int?
    private let errors: [Int: SubtitleTranslationError]
    private var holdFirst: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var requests: [[UUID]] = []
    private(set) var settingsUsed: [TranslationSettings] = []
    init(failCall: Int? = nil, holdFirstCall: Bool = false, errors: [Int: SubtitleTranslationError] = [:]) {
        self.failCall = failCall; holdFirst = holdFirstCall; self.errors = errors
    }
    func waitForRequest() async {
        if held != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func releaseRequest() { held?.resume(); held = nil }
    func translate(settings: TranslationSettings, request: SubtitleTranslationRequest) async throws -> [TranslationBatchOutput] {
        settingsUsed.append(settings)
        requests.append(request.inputs.map(\.cueID))
        if holdFirst {
            holdFirst = false
            await withCheckedContinuation { held = $0; observer?.resume(); observer = nil }
        }
        if let error = errors[requests.count] { throw error }
        if failCall == requests.count { throw SubtitleTranslationError.httpFailure(400) }
        return request.inputs.map { .init(cueID: $0.cueID, text: "Test-only translation") }
    }
}

private actor RetrySleepRecorder {
    private(set) var durations: [Duration] = []
    private let hold: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(hold: Bool = false) { self.hold = hold }
    func record(_ duration: Duration) { durations.append(duration) }
    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        if hold { await withCheckedContinuation { held = $0; observer?.resume(); observer = nil } }
        try Task.checkCancellation()
    }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { held?.resume(); held = nil }
}

private struct TranslationNotExpected: SubtitleTranslationPipeline {
    func translate(settings: TranslationSettings, request: SubtitleTranslationRequest) async throws -> [TranslationBatchOutput] {
        Issue.record("Translation was invoked for a transcription-only task")
        throw QueueError.unavailable("Unexpected translation in a transcription-only test")
    }
}

private struct UnavailableServicePipeline: SubtitleTranslationPipeline {
    func translate(settings: TranslationSettings, request: SubtitleTranslationRequest) async throws -> [TranslationBatchOutput] {
        throw TranslationServiceError.unknownService
    }
}
