import Foundation
import Testing
@testable import VoxlineCore

@Suite("Durable processing checkpoints")
struct ProcessingCheckpointTests {
    private let ranges = [TranscriptionChunkRange(sourceStartMilliseconds: 0, durationMilliseconds: 2000),
                          TranscriptionChunkRange(sourceStartMilliseconds: 2000, durationMilliseconds: 2000)]

    private func task(translates: Bool = false, apple: Bool = false) throws -> ProcessingTask {
        let media = try MediaIdentity(fileName: "sample.mp4", byteCount: 123, sha256: String(repeating: "a", count: 64),
                                      durationMilliseconds: 5000, audioTrackID: 1)
        let translation = apple ? try TranslationSettings(appleSourceLanguage: "en", targetLanguage: "zh-Hans", batchSize: 7) : translates ? try TranslationSettings(baseURL: URL(string: "https://example.test/v1")!,
            modelID: "model", targetLanguage: "zh-Hans", serviceID: UUID()) : nil
        let parameters = TaskParameters(transcription: .whisperKitBaseline, translation: translation)
        var task = ProcessingTask(items: [.init(title: "Sample", kind: .video,
            source: .localFile(fileName: media.fileName), media: media)], parameters: parameters)
        try task.freezeParameters()
        try task.items[0].initializeCheckpoint(parameters: parameters, ranges: ranges)
        return task
    }

    @Test func nativeParametersAndCommittedBatchesSurviveMigrationAndRecovery() throws {
        var original = try task(apple: true)
        _ = try complete(&original, index: 0)
        _ = try complete(&original, index: 1)
        let ids = original.items[0].cues.map(\.id)
        let first = try original.items[0].prepareTranslationBatch(cueIDs: [ids[0]])
        try original.items[0].beginTranslationBatch(first)
        try original.items[0].commitTranslationBatch(first, outputs: [.init(cueID: ids[0], text: "保留")])
        let second = try original.items[0].prepareTranslationBatch(cueIDs: [ids[1]])
        try original.items[0].beginTranslationBatch(second)
        try original.items[0].recordTranslationFailure(second, reason: "Language download cancelled")
        let data = try TaskDocumentCodec.encode(original)
        #expect(!String(decoding: data, as: UTF8.self).contains("baseURL"))
        #expect(!String(decoding: data, as: UTF8.self).contains("systemPrompt"))
        var reopened = try TaskDocumentCodec.decode(data)
        #expect(reopened == original)
        #expect(reopened.parameters.translation?.api == nil)
        #expect(reopened.parameters.translation?.engine == .appleTranslation(sourceLanguage: "en"))
        #expect(reopened.parameters.translation?.batchSize == 7)
        try reopened.items[0].beginTranslationBatch(second)
        try reopened.items[0].commitTranslationBatch(second, outputs: [.init(cueID: ids[1], text: "继续")])
        #expect(reopened.items[0].status == .completed)
        #expect(reopened.items[0].cues.map(\.translation) == [
            .succeeded(text: "保留", sourceRevision: 1), .succeeded(text: "继续", sourceRevision: 1)])
    }

    @Test func versionFourFlatAPISettingsKeepFrozenParameters() throws {
        let original = try task(translates: true)
        let api = try #require(original.parameters.translation?.api)
        var object = try #require(JSONSerialization.jsonObject(with: TaskDocumentCodec.encode(original)) as? [String: Any])
        object["formatVersion"] = 4
        var parameters = try #require(object["parameters"] as? [String: Any])
        parameters["translation"] = ["baseURL": api.baseURL.absoluteString, "modelID": api.modelID,
            "serviceID": try #require(api.serviceID).uuidString, "targetLanguage": "zh-Hans",
            "batchSize": 30, "systemPrompt": api.systemPrompt] as [String: Any]
        object["parameters"] = parameters
        var items = try #require(object["items"] as? [[String: Any]])
        var checkpoint = try #require(items[0]["checkpoint"] as? [String: Any])
        checkpoint["parameters"] = parameters
        items[0]["checkpoint"] = checkpoint
        object["items"] = items
        #expect(try TaskDocumentCodec.decode(JSONSerialization.data(withJSONObject: object)) == original)
    }

    @Test func versionThreeMigratesTranslationDefaultsInTaskAndCheckpointWithoutChangingResults() throws {
        var original = try task(translates: true)
        _ = try complete(&original, index: 0)
        var object = try #require(try JSONSerialization.jsonObject(with: TaskDocumentCodec.encode(original)) as? [String: Any])
        object["formatVersion"] = 3
        var parameters = try #require(object["parameters"] as? [String: Any])
        let api = try #require(original.parameters.translation?.api)
        var translation: [String: Any] = ["baseURL": api.baseURL.absoluteString,
            "modelID": api.modelID, "serviceID": try #require(api.serviceID).uuidString,
            "targetLanguage": try #require(original.parameters.translation).targetLanguage]
        translation.removeValue(forKey: "batchSize")
        translation.removeValue(forKey: "systemPrompt")
        parameters["translation"] = translation
        object["parameters"] = parameters
        var items = try #require(object["items"] as? [[String: Any]])
        var checkpoint = try #require(items[0]["checkpoint"] as? [String: Any])
        checkpoint["parameters"] = parameters
        items[0]["checkpoint"] = checkpoint
        object["items"] = items
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let migrated = try TaskDocumentCodec.decode(legacy)
        #expect(migrated == original)
        #expect(migrated.formatVersion == ProcessingTask.currentFormatVersion)
        #expect(migrated.parameters.translation?.batchSize == 30)
        #expect(migrated.parameters.translation?.api?.systemPrompt == TranslationSettings.defaultSystemPrompt)
        #expect(migrated.items[0].checkpoint?.parameters == migrated.parameters)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(migrated)) == migrated)
        for invalid in [NSNull(), 0, "seven"] as [Any] {
            translation["batchSize"] = invalid
            parameters["translation"] = translation
            object["parameters"] = parameters
            #expect(throws: (any Error).self) {
                try TaskDocumentCodec.decode(JSONSerialization.data(withJSONObject: object))
            }
        }
        translation["batchSize"] = 30
        translation["systemPrompt"] = "  "
        parameters["translation"] = translation
        object["parameters"] = parameters
        #expect(throws: ProjectValidationError.emptyTranslationSystemPrompt) {
            try TaskDocumentCodec.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    private func evidence(range: TranscriptionChunkRange, settings: TranscriptionSettings = .whisperKitBaseline,
                          outcome: TranscriptionEvidence.Outcome = .completed) throws -> TranscriptionEvidence {
        let audio = try TranscriptionAudio(localURL: URL(fileURLWithPath: "/tmp/not-needed.wav"),
            sourceStartMilliseconds: range.sourceStartMilliseconds, durationMilliseconds: range.durationMilliseconds)
        var evidence = TranscriptionEvidence(settings: settings, audio: audio)
        let start = Double(range.sourceStartMilliseconds) / 1000 + 0.2
        let word = RawWordTiming(text: " Keep.", startSeconds: start, endSeconds: start + 0.5, probability: 0.9)
        evidence.segments = [.init(startSeconds: start, endSeconds: start + 0.5, text: word.text, words: [word])]
        evidence.outcome = outcome
        if outcome == .failed { evidence.failureReason = "Alignment failed" }
        return evidence
    }

    private func complete(_ task: inout ProcessingTask, index: Int) throws -> SubtitleSegmentationResult {
        let chunk = try #require(task.items[0].checkpoint?.chunks[index])
        let sourceID = try task.items[0].beginTranscriptionChunk(chunk.id)
        let result = try SubtitleSegmenter.segment(evidence(range: chunk.range), sourceID: sourceID,
                                                   mediaDurationMilliseconds: 5000)
        try task.items[0].commitTranscriptionChunk(chunk.id, result: result)
        return result
    }

    @Test func proofreadingTracksCurrentTranslationAndPreservesConcurrentTiming() throws {
        var task = try task(translates: true)
        _ = try complete(&task, index: 0)
        _ = try complete(&task, index: 1)
        let batch = try task.items[0].prepareTranslationBatch(cueIDs: task.items[0].cues.map(\.id))
        try task.items[0].beginTranslationBatch(batch)
        try task.items[0].commitTranslationBatch(batch, outputs: task.items[0].cues.map {
            .init(cueID: $0.id, text: "Original translation")
        })
        let original = task.items[0].cues[0]
        let evidence = task.items[0].checkpoint
        task.items[0].cues[0].startMilliseconds += 50
        task.items[0].cues[0].endMilliseconds += 50
        try task.items[0].editSubtitle(comparedTo: original, sourceText: "Corrected", translationText: "Original translation")
        #expect(task.items[0].status == .needsReview)
        #expect(task.items[0].cues[0].sourceRevision == 2)
        #expect(task.items[0].cues[0].translation == .succeeded(text: "Original translation", sourceRevision: 1))
        #expect(task.items[0].cues[0].startMilliseconds == original.startMilliseconds + 50)
        let corrected = task.items[0].cues[0]
        let beforeConflict = task
        #expect(throws: CheckpointError.editedCue) {
            try task.items[0].editSubtitle(comparedTo: original, sourceText: "Stale draft", translationText: "Stale")
        }
        #expect(task == beforeConflict)
        try task.items[0].editSubtitle(comparedTo: corrected, sourceText: corrected.sourceText, translationText: "Current translation")
        #expect(task.items[0].status == .completed)
        #expect(task.items[0].cues[0].translation == .succeeded(text: "Current translation", sourceRevision: 2))
        #expect(task.items[0].checkpoint == evidence)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task)) == task)
    }

    @Test func proofreadingKeepsTimingReviewLegacyAndFailureStates() throws {
        var task = try task()
        _ = try complete(&task, index: 0)
        _ = try complete(&task, index: 1)
        task.items[0].cues[0].requiresTimingReview = true
        task.items[0].status = .needsReview
        let original = task.items[0].cues[0]
        try task.items[0].editSubtitle(comparedTo: original, sourceText: "Reviewed text", translationText: "")
        #expect(task.items[0].status == .needsReview)
        try task.items[0].confirmTimingReview(cueID: original.id)
        #expect(task.items[0].status == .completed)
        var legacy = task.items[0]
        legacy.checkpoint = nil
        legacy.status = .needsReview
        try legacy.editSubtitle(comparedTo: legacy.cues[0], sourceText: "Legacy edit", translationText: "")
        #expect(legacy.status == .needsReview)
        task.items[0].status = .failed(reason: "Unresolved service failure")
        try task.items[0].editSubtitle(comparedTo: task.items[0].cues[0], sourceText: "Another edit", translationText: "")
        #expect(task.items[0].status == .failed(reason: "Unresolved service failure"))
    }

    @Test func recoveredTimingsRequireExplicitReviewAfterTranslationAndSurviveRestart() throws {
        var original = try task(translates: true)
        _ = try complete(&original, index: 0)
        let chunk = try #require(original.items[0].checkpoint?.chunks[1])
        let sourceID = try original.items[0].beginTranscriptionChunk(chunk.id)
        var recovered = try evidence(range: chunk.range)
        let raw = RawTranscriptionSegment(startSeconds: 2.2, endSeconds: 2.7, text: " Keep.", words: nil)
        let collapsed = RawTranscriptionSegment(startSeconds: 2.7, endSeconds: 2.7, text: raw.text, words: nil)
        recovered.segments = [raw]
        recovered.windows = [.init(seekFrame: 0, frameCount: 32000, decodedText: raw.text, decodedTokens: [],
            language: "en", skippedAsNoSpeech: false, segmentsBeforeAlignment: [raw],
            alignedSegments: [collapsed], usesSegmentTimings: true)]
        let result = try SubtitleSegmenter.segment(recovered, sourceID: sourceID, mediaDurationMilliseconds: 5000)
        #expect(result.cues[0].requiresTimingReview == true)
        try original.items[0].commitTranscriptionChunk(chunk.id, result: result)
        let batchID = try original.items[0].prepareTranslationBatch(cueIDs: original.items[0].cues.map(\.id))
        try original.items[0].beginTranslationBatch(batchID)
        try original.items[0].commitTranslationBatch(batchID, outputs: original.items[0].cues.map {
            TranslationBatchOutput(cueID: $0.id, text: "保留。")
        })
        #expect(original.items[0].status == .needsReview)
        var reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(original))
        #expect(reopened == original)
        try reopened.items[0].confirmTimingReview(cueID: result.cues[0].id)
        #expect(reopened.items[0].status == .completed)
        #expect(reopened.items[0].cues.last?.requiresTimingReview == nil)
        #expect(reopened.items[0].checkpoint == original.items[0].checkpoint)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(reopened)) == reopened)
    }

    @Test func restartSkipsCommittedChunksAndKeepsEditedCuesAndRawEvidence() throws {
        var original = try task()
        let result = try complete(&original, index: 0)
        try original.items[0].cues[0].replaceSourceText(with: "Corrected")
        original.items[0].cues[0].startMilliseconds += 50
        original.items[0].cues[0].endMilliseconds += 50
        let unfinished = try #require(original.items[0].checkpoint?.chunks[1].id)
        _ = try original.items[0].beginTranscriptionChunk(unfinished)
        var reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(original))
        reopened.interruptRunningItems()
        let record = try #require(reopened.items[0].checkpoint)
        #expect(record.chunks[1].state == .interrupted)
        #expect(reopened.items[0].status == .interrupted(stage: .transcription))
        let plan = try reopened.items[0].recoveryPlan(media: record.media, parameters: reopened.parameters, ranges: ranges)
        #expect(plan.transcriptionChunkIDs == [unfinished])
        #expect(reopened.items[0].cues == original.items[0].cues)
        if case .completed(let saved) = record.chunks[0].state { #expect(saved == result) }
        else { Issue.record("Committed evidence missing") }
        try reopened.items[0].commitTranscriptionChunk(record.chunks[0].id, result: result)
        #expect(reopened.items[0].cues == original.items[0].cues)
        _ = try complete(&reopened, index: 1)
        #expect(reopened.items[0].cues.count == 2)
        #expect(reopened.items[0].cues[0].sourceText == "Corrected")
        #expect(reopened.items[0].status == .completed)
    }

    @Test func failureNaNAndCancellationSurviveSavingWithoutDependingOnCaches() throws {
        var task = try task()
        _ = try complete(&task, index: 0)
        let chunk = try #require(task.items[0].checkpoint?.chunks[1])
        let attempt = try task.items[0].beginTranscriptionChunk(chunk.id)
        var failed = try evidence(range: chunk.range, outcome: .failed)
        failed.segments = [.init(startSeconds: .nan, endSeconds: .infinity, text: "Do not lose this", words: nil)]
        try task.items[0].recordTranscriptionFailure(chunk.id, sourceID: attempt, reason: "Alignment failed", evidence: failed)
        let data = try TaskDocumentCodec.encode(task)
        var reopened = try TaskDocumentCodec.decode(data)
        #expect(task == reopened)
        #expect(task.items[0].cues.count == 1)
        #expect(reopened.items[0].status == .failed(reason: "Alignment failed"))
        let record = try #require(reopened.items[0].checkpoint)
        #expect(try reopened.items[0].recoveryPlan(media: record.media, parameters: reopened.parameters, ranges: ranges).transcriptionChunkIDs == [chunk.id])
        let retry = try reopened.items[0].beginTranscriptionChunk(chunk.id)
        #expect(retry != attempt)
        let stale = try SubtitleSegmenter.segment(evidence(range: chunk.range), sourceID: attempt, mediaDurationMilliseconds: 5000)
        #expect(throws: CheckpointError.staleResult) { try reopened.items[0].commitTranscriptionChunk(chunk.id, result: stale) }
        var cancelled = try evidence(range: chunk.range, outcome: .cancelled)
        cancelled.partialDecodedText = "Partial words"
        cancelled.partialDecodedTokens = [1, 2]
        try reopened.items[0].recordTranscriptionCancellation(chunk.id, sourceID: retry, evidence: cancelled)
        let final = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(reopened))
        #expect(final == reopened)
        #expect(final.items[0].status == .cancelled)
        #expect(final.items[0].cues == task.items[0].cues)
    }

    @Test func retryingAnEarlierFailurePreservesLaterResultsInSourceOrder() throws {
        var task = try task()
        let first = try #require(task.items[0].checkpoint?.chunks[0])
        let attempt = try task.items[0].beginTranscriptionChunk(first.id)
        try task.items[0].recordTranscriptionFailure(first.id, sourceID: attempt, reason: "Failed", evidence: nil)
        _ = try complete(&task, index: 1)
        try task.items[0].cues[0].replaceSourceText(with: "Later manual edit")
        _ = try complete(&task, index: 0)
        #expect(task.items[0].cues.map(\.sourceText) == ["Keep.", "Later manual edit"])
        #expect(task.items[0].cues.map(\.startMilliseconds) == [200, 2200])
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task)) == task)
    }

    @Test func contextRangeAndCorruptResultCannotReplacePriorWork() throws {
        var task = try task()
        let record = try #require(task.items[0].checkpoint)
        var parameters = task.parameters
        parameters.transcription = .init(modelID: "different-model")
        #expect(throws: CheckpointError.incompatibleContext) {
            try task.items[0].recoveryPlan(media: record.media, parameters: parameters, ranges: ranges)
        }
        let differentTrack = try MediaIdentity(fileName: record.media.fileName, byteCount: record.media.byteCount,
            sha256: record.media.sha256, durationMilliseconds: 5000, audioTrackID: 2)
        #expect(throws: CheckpointError.incompatibleContext) {
            try task.items[0].recoveryPlan(media: differentTrack, parameters: task.parameters, ranges: ranges)
        }
        #expect(throws: CheckpointError.incompatibleContext) {
            try task.items[0].recoveryPlan(media: record.media, parameters: task.parameters, ranges: ranges.reversed())
        }
        let chunk = record.chunks[0]
        let attempt = try task.items[0].beginTranscriptionChunk(chunk.id)
        let wrong = try SubtitleSegmenter.segment(evidence(range: ranges[1]), sourceID: attempt, mediaDurationMilliseconds: 5000)
        let before = task
        #expect(throws: CheckpointError.incompatibleContext) { try task.items[0].commitTranscriptionChunk(chunk.id, result: wrong) }
        #expect(task == before)
        let cancelled = try evidence(range: chunk.range, outcome: .cancelled)
        let invalid = SubtitleSegmentationResult(sourceID: attempt, evidence: cancelled, policy: .readable,
            entries: [], excludedEmptySegmentIndices: [])
        #expect(throws: SubtitleSegmentationError.incompleteTranscription) { try task.items[0].commitTranscriptionChunk(chunk.id, result: invalid) }
        #expect(task == before)
    }

    @Test func translationBatchesResumeWithoutRepeatingCommittedResults() throws {
        var task = try task(translates: true)
        _ = try complete(&task, index: 0)
        _ = try complete(&task, index: 1)
        let ids = task.items[0].cues.map(\.id)
        let first = try task.items[0].prepareTranslationBatch(cueIDs: [ids[0]])
        try task.items[0].beginTranslationBatch(first)
        let output = [TranslationBatchOutput(cueID: ids[0], text: "保留")]
        try task.items[0].commitTranslationBatch(first, outputs: output)
        let second = try task.items[0].prepareTranslationBatch(cueIDs: [ids[1]])
        try task.items[0].beginTranslationBatch(second)
        var reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task))
        reopened.interruptRunningItems()
        let record = try #require(reopened.items[0].checkpoint)
        let plan = try reopened.items[0].recoveryPlan(media: record.media, parameters: reopened.parameters, ranges: ranges)
        #expect(plan.transcriptionChunkIDs.isEmpty)
        #expect(plan.translationBatchIDs == [second])
        #expect(plan.untranslatedCueIDs.isEmpty)
        try reopened.items[0].commitTranslationBatch(first, outputs: output)
        try reopened.items[0].beginTranslationBatch(second)
        try reopened.items[0].commitTranslationBatch(second, outputs: [.init(cueID: ids[1], text: "继续")])
        #expect(reopened.items[0].status == .completed)
        #expect(reopened.items[0].cues.allSatisfy { $0.hasCurrentTranslation })
        try reopened.items[0].cues[0].replaceSourceText(with: "Edited again")
        reopened.items[0].status = .needsReview
        let edited = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(reopened))
        #expect(edited.items[0].cues[0].translation == .succeeded(text: "保留", sourceRevision: 1))
        #expect(!edited.items[0].cues[0].hasCurrentTranslation)
        #expect(try edited.items[0].recoveryPlan(media: record.media, parameters: edited.parameters, ranges: ranges).untranslatedCueIDs == [ids[0]])
    }

    @Test(arguments: [true, false])
    func translationCannotOverwriteSourceOrTranslationEditedWhileWaiting(editSource: Bool) throws {
        var task = try task(translates: true)
        _ = try complete(&task, index: 0)
        _ = try complete(&task, index: 1)
        let id = task.items[0].cues[0].id
        let batch = try task.items[0].prepareTranslationBatch(cueIDs: [id])
        try task.items[0].beginTranslationBatch(batch)
        if editSource { try task.items[0].cues[0].replaceSourceText(with: "Corrected") }
        else { task.items[0].cues[0].translation = .succeeded(text: "Manual", sourceRevision: 1) }
        let edited = task
        #expect(throws: CheckpointError.editedCue) {
            try task.items[0].commitTranslationBatch(batch, outputs: [.init(cueID: id, text: "Automatic")])
        }
        #expect(task == edited)
        var reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task))
        reopened.interruptRunningItems()
        let record = try #require(reopened.items[0].checkpoint)
        let plan = try reopened.items[0].recoveryPlan(media: record.media, parameters: reopened.parameters, ranges: ranges)
        #expect(plan.outdatedTranslationBatchIDs == [batch])
        #expect(plan.translationBatchIDs.isEmpty)
        if editSource {
            let newBatch = try reopened.items[0].prepareTranslationBatch(cueIDs: [id])
            try reopened.items[0].beginTranslationBatch(newBatch)
            try reopened.items[0].commitTranslationBatch(newBatch, outputs: [.init(cueID: id, text: "Current translation")])
        } else {
            #expect(plan.untranslatedCueIDs.allSatisfy { $0 != id })
            #expect(reopened.items[0].cues[0].translation == .succeeded(text: "Manual", sourceRevision: 1))
        }
    }

    @Test func malformedBatchResultsAreAtomicAndFailureOrCancellationCanRetry() throws {
        var task = try task(translates: true)
        _ = try complete(&task, index: 0)
        _ = try complete(&task, index: 1)
        let ids = task.items[0].cues.map(\.id)
        let batch = try task.items[0].prepareTranslationBatch(cueIDs: ids)
        try task.items[0].beginTranslationBatch(batch)
        let before = task
        for outputs in [[TranslationBatchOutput](), [.init(cueID: ids[0], text: "First")],
                        [.init(cueID: ids[0], text: "First"), .init(cueID: ids[0], text: "Duplicate")],
                        [.init(cueID: ids[0], text: "First"), .init(cueID: ids[1], text: " ")]] {
            #expect(throws: CheckpointError.invalidTranslationResult) { try task.items[0].commitTranslationBatch(batch, outputs: outputs) }
            #expect(task == before)
        }
        try task.items[0].recordTranslationFailure(batch, reason: "HTTP failure")
        var reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task))
        try reopened.items[0].beginTranslationBatch(batch)
        try reopened.items[0].recordTranslationCancellation(batch)
        reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(reopened))
        try reopened.items[0].beginTranslationBatch(batch)
        try reopened.items[0].commitTranslationBatch(batch, outputs: ids.map { .init(cueID: $0, text: "Done") })
        #expect(reopened.items[0].status == .completed)
    }

    @Test func anotherBatchCompletionKeepsTheUnresolvedFailureAndEditedTiming() throws {
        var task = try task(translates: true)
        _ = try complete(&task, index: 0)
        _ = try complete(&task, index: 1)
        let ids = task.items[0].cues.map(\.id)
        let failed = try task.items[0].prepareTranslationBatch(cueIDs: [ids[0]])
        try task.items[0].beginTranslationBatch(failed)
        let second = try task.items[0].prepareTranslationBatch(cueIDs: [ids[1]])
        #expect(task.items[0].status == .running(stage: .translation))
        try task.items[0].recordTranslationFailure(failed, reason: "Service failure")
        try task.items[0].beginTranslationBatch(second)
        task.items[0].cues[1].startMilliseconds += 50
        task.items[0].cues[1].endMilliseconds += 50
        try task.items[0].commitTranslationBatch(second, outputs: [.init(cueID: ids[1], text: "Success")])
        #expect(task.items[0].status == .failed(reason: "Service failure"))
        #expect(task.items[0].cues[1].startMilliseconds == 2250)
        let saved = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task))
        let record = try #require(saved.items[0].checkpoint)
        #expect(try saved.items[0].recoveryPlan(media: record.media, parameters: saved.parameters, ranges: ranges).translationBatchIDs == [failed])
    }

    @Test func checkpointCannotClipTimingEditsOrAcceptMissingDerivedText() throws {
        var task = try task()
        _ = try complete(&task, index: 0)
        let next = try #require(task.items[0].checkpoint?.chunks[1])
        let sourceID = try task.items[0].beginTranscriptionChunk(next.id)
        task.items[0].cues[0].startMilliseconds += 2000
        task.items[0].cues[0].endMilliseconds += 2000
        let candidate = try SubtitleSegmenter.segment(evidence(range: next.range), sourceID: sourceID, mediaDurationMilliseconds: 5000)
        let edited = task
        #expect(throws: ProjectValidationError.overlappingOrUnorderedCue(candidate.cues[0].id)) {
            try task.items[0].commitTranscriptionChunk(next.id, result: candidate)
        }
        #expect(task == edited)
        let invalid = SubtitleSegmentationResult(sourceID: sourceID, evidence: candidate.evidence,
            policy: candidate.policy, entries: [], excludedEmptySegmentIndices: [])
        #expect(throws: CheckpointError.invalidRecord) { try task.items[0].commitTranscriptionChunk(next.id, result: invalid) }
        #expect(task == edited)
    }

    @Test func versionTwoMigrationPreservesResultsWithoutInventingCheckpoints() throws {
        var original = ProcessingTask(items: [.init(title: "Legacy", kind: .audio, source: .unassociated)])
        original.items[0].cues = [try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 500, sourceText: "Keep")]
        var object = try #require(JSONSerialization.jsonObject(with: TaskDocumentCodec.encode(original)) as? [String: Any])
        object["formatVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)
        let reopened = try TaskDocumentCodec.decode(data)
        #expect(reopened.formatVersion == ProcessingTask.currentFormatVersion)
        #expect(reopened.id == original.id)
        #expect(reopened.items == original.items)
        #expect(reopened.items[0].checkpoint == nil)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(reopened)) == reopened)
        var invalid = try task()
        invalid.items[0].status = .completed
        #expect(throws: CheckpointError.incompleteWork) { try TaskDocumentCodec.encode(invalid) }
        var corrupted = try #require(JSONSerialization.jsonObject(with: TaskDocumentCodec.encode(task())) as? [String: Any])
        corrupted["formatVersion"] = 2
        #expect(throws: CheckpointError.invalidRecord) {
            try TaskDocumentCodec.decode(JSONSerialization.data(withJSONObject: corrupted))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_AUDIO_CACHE_MANIFEST"] != nil))
    func realSavedS001EvidenceSurvivesDocumentReopeningAndCacheRemoval() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["VOXLINE_TRANSCRIPTION_EVIDENCE_DIRECTORY"])
        let manifestPath = try #require(environment["VOXLINE_AUDIO_CACHE_MANIFEST"])
        struct AudioManifest: Decodable {
            struct Chunk: Decodable { let sourceStartFrame: Int64; let frameCount: Int64 }
            let identity: MediaIdentity
            let chunks: [Chunk]
        }
        let manifest = try JSONDecoder().decode(AudioManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let declaredRanges = manifest.chunks.map {
            TranscriptionChunkRange(sourceStartMilliseconds: $0.sourceStartFrame / 16,
                durationMilliseconds: $0.frameCount / 16 + ($0.frameCount % 16 == 0 ? 0 : 1))
        }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("evidence-cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        for file in files { try FileManager.default.copyItem(at: file, to: cache.appendingPathComponent(file.lastPathComponent)) }
        let copied = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        let inputs = try copied.map { try decoder.decode(TranscriptionEvidence.self, from: Data(contentsOf: $0)) }
            .filter { evidence in declaredRanges.contains {
                $0.sourceStartMilliseconds == evidence.sourceStartMilliseconds && $0.durationMilliseconds == evidence.durationMilliseconds
            } }.sorted { $0.sourceStartMilliseconds < $1.sourceStartMilliseconds }
        try #require(inputs.count == declaredRanges.count, "Select exactly one saved evidence record for each S001 chunk")
        let first = try #require(inputs.first)
        let parameters = TaskParameters(transcription: first.settings)
        var task = ProcessingTask(items: [.init(title: "S001", kind: .video,
            source: .localFile(fileName: manifest.identity.fileName), media: manifest.identity)], parameters: parameters)
        try task.freezeParameters()
        try task.items[0].initializeCheckpoint(parameters: parameters, ranges: declaredRanges)
        let url = directory.appendingPathComponent("sample.voxline")
        var completed = 0
        var failed = 0
        for (index, evidence) in inputs.enumerated() {
            let chunkID = try #require(task.items[0].checkpoint?.chunks[index].id)
            let sourceID = try task.items[0].beginTranscriptionChunk(chunkID)
            try TaskDocumentCodec.encode(task).write(to: url, options: .atomic)
            if evidence.outcome == .completed {
                let result = try SubtitleSegmenter.segment(evidence, sourceID: sourceID,
                    mediaDurationMilliseconds: manifest.identity.durationMilliseconds)
                try task.items[0].commitTranscriptionChunk(chunkID, result: result)
                completed += 1
            } else {
                let reason = try #require(evidence.failureReason)
                try task.items[0].recordTranscriptionFailure(chunkID, sourceID: sourceID, reason: reason, evidence: evidence)
                failed += 1
            }
            try TaskDocumentCodec.encode(task).write(to: url, options: .atomic)
            let saved = try TaskDocumentCodec.decode(Data(contentsOf: url))
            #expect(saved == task)
            task = saved
        }
        let record = try #require(task.items[0].checkpoint)
        let plan = try task.items[0].recoveryPlan(media: manifest.identity, parameters: parameters, ranges: declaredRanges)
        #expect(plan.transcriptionChunkIDs == record.chunks.filter { !$0.isCompleted }.map(\.id))
        #expect(plan.transcriptionChunkIDs.count == failed)
        #expect(completed > 0)
        #expect(failed > 0)
        #expect(task.items[0].status.isFailedForTest)
        try FileManager.default.removeItem(at: cache)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)) == task)
        // Only the temporary copy is removed; the private source evidence stays available.
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(path))
        print("S001_CHECKPOINT completed=\(completed) failed=\(failed) cues=\(task.items[0].cues.count) retry=\(plan.transcriptionChunkIDs.count)")
    }
}

private extension TaskMediaStatus {
    var isFailedForTest: Bool { if case .failed = self { true } else { false } }
}
