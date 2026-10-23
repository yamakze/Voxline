import Foundation
import Testing
@testable import VoxlineCore

@Suite("Durable processing checkpoints")
struct ProcessingCheckpointTests {
    @Test func plannedBatchesKeepRunningBetweenCommitsAndRestartAtTranslation() throws {
        var processing = try task(translates: true)
        _ = try complete(&processing, index: 0)
        _ = try complete(&processing, index: 1)
        let ids = processing.items[0].cues.map(\.id)
        let batches = try processing.items[0].prepareTranslationBatches(cueIDBatches: ids.map { [$0] })
        let workIndex = try TranslationCheckpointIndex(item: processing.items[0])
        try processing.items[0].beginTranslationBatch(batches[0], using: workIndex)
        try processing.items[0].commitTranslationBatch(batches[0], outputs: [.init(cueID: ids[0], text: "First")], using: workIndex)
        #expect(processing.items[0].status == .running(stage: .translation))
        var restarted = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(processing))
        restarted.interruptRunningItems()
        #expect(restarted.items[0].status == .interrupted(stage: .translation))
        try restarted.items[0].beginTranslationBatch(batches[1], using: workIndex)
        try restarted.items[0].commitTranslationBatch(batches[1], outputs: [.init(cueID: ids[1], text: "Second")], using: workIndex)
        #expect(restarted.items[0].status == .completed)
        #expect(restarted.items[0].cues[0].translation == processing.items[0].cues[0].translation)
    }

    @Test func duplicateIDsReportAnErrorAndBatchPlanningIsAtomic() throws {
        var processing = try task(translates: true)
        _ = try complete(&processing, index: 0)
        _ = try complete(&processing, index: 1)
        let original = processing.items[0]
        let id = original.cues[0].id
        #expect(throws: CheckpointError.invalidTranslationResult) {
            try processing.items[0].prepareTranslationBatches(cueIDBatches: [[id], [id]])
        }
        #expect(processing.items[0] == original)
        processing.items[0].cues.append(original.cues[0])
        #expect(throws: DomainValidationError.duplicateCue(id)) {
            try processing.items[0].prepareTranslationBatch(cueIDs: [id])
        }
    }

    @Test func alternatePlaybackMediaPreservesCompletedEvidenceEditsAndTranslationRecovery() throws {
        var original = try task(translates: true)
        _ = try complete(&original, index: 0)
        _ = try complete(&original, index: 1)
        let record = try #require(original.items[0].checkpoint)
        let cues = original.items[0].cues
        let alternate = try MediaIdentity(fileName: "HD.mov", byteCount: 321, fingerprint: String(repeating: "b", count: 64),
                                          durationMilliseconds: 5000, audioTrackID: 7)
        try original.items[0].associateMedia(alternate)
        let reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(original))
        #expect(reopened.items[0].media == alternate)
        #expect(reopened.items[0].cues == cues)
        #expect(reopened.items[0].checkpoint == record)
        var translated = reopened
        let batch = try translated.items[0].prepareTranslationBatch(cueIDs: cues.map(\.id))
        try translated.items[0].beginTranslationBatch(batch)
        try translated.items[0].commitTranslationBatch(batch, outputs: cues.map { .init(cueID: $0.id, text: "保留。")} )
        #expect(translated.items[0].status == .completed)
        #expect(translated.items[0].checkpoint?.chunks == record.chunks)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(translated)) == translated)
    }
    @Test func coarseCloudTimingUsesTheSameAbsoluteMillisecondEndpoint() throws {
        let settings = TranscriptionSettings(provider: .openAICompatible, modelID: "qwen3-asr-flash",
            cloud: .init(serviceID: UUID(), baseURL: URL(string: "https://example.test/v1")!, protocolKind: .qwenAudioChat))
        let audio = try TranscriptionAudio(localURL: URL(fileURLWithPath: "/unused.wav"),
            sourceStartMilliseconds: 234520, durationMilliseconds: 740)
        var evidence = TranscriptionEvidence(settings: settings, audio: audio)
        evidence.cloudResult = .init(text: "はい。", segments: nil, timingSource: .audioRange)
        let completed = try CloudTranscriptionAlignment.completedEvidence(from: evidence)
        let result = try SubtitleSegmenter.segment(completed, sourceID: UUID(), mediaDurationMilliseconds: 235260)
        #expect(result.cues.count == 1)
        #expect(result.cues.first?.startMilliseconds == 234520)
        #expect(result.cues.first?.endMilliseconds == 235260)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_CLOUD_TASK_FIXTURE"] != nil))
    func realCloudFailedRangesRecoverWithoutChangingCommittedCues() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXLINE_CLOUD_TASK_FIXTURE"])
        let original = try TaskDocumentCodec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        var recovered = original
        var count = 0
        for index in recovered.items.indices {
            let chunks = try #require(recovered.items[index].checkpoint?.chunks)
            for chunk in chunks {
                guard case .failed(_, let evidence) = chunk.state, let evidence, evidence.cloudResult != nil else { continue }
                let completed = try CloudTranscriptionAlignment.completedEvidence(from: evidence)
                let sourceID = try recovered.items[index].beginTranscriptionChunk(chunk.id)
                let result = try SubtitleSegmenter.segment(completed, sourceID: sourceID,
                    mediaDurationMilliseconds: recovered.items[index].media!.durationMilliseconds)
                try recovered.items[index].commitTranscriptionChunk(chunk.id, result: result)
                count += 1
            }
            for cue in original.items[index].cues {
                #expect(recovered.items[index].cues.first(where: { $0.id == cue.id }) == cue)
            }
            for chunk in chunks where chunk.isCompleted {
                #expect(recovered.items[index].checkpoint?.chunks.first(where: { $0.id == chunk.id }) == chunk)
            }
        }
        #expect(count > 0)
        #expect(recovered.items.allSatisfy { item in
            item.checkpoint?.chunks.allSatisfy { chunk in
                if case .failed(_, let evidence) = chunk.state { return evidence?.cloudResult == nil }
                return true
            } ?? true
        })
        #expect(recovered.parameters == original.parameters)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(recovered)) == recovered)
    }

    @Test(arguments: [ProcessingStage.audioExtraction, .transcription, .translation])
    func reopenedWorkShowsPausedCurrentStage(stage: ProcessingStage) throws {
        var processing = try task(translates: true)
        switch stage {
        case .audioExtraction:
            processing.items[0].checkpoint = nil
            processing.items[0].status = .running(stage: stage)
        case .transcription:
            let chunk = try #require(processing.items[0].checkpoint?.chunks.first)
            _ = try processing.items[0].beginTranscriptionChunk(chunk.id)
        case .translation:
            _ = try complete(&processing, index: 0)
            _ = try complete(&processing, index: 1)
            let batch = try processing.items[0].prepareTranslationBatch(cueIDs: processing.items[0].cues.map(\.id))
            try processing.items[0].beginTranslationBatch(batch)
        }
        var reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(processing))
        reopened.interruptRunningItems()
        let item = reopened.items[0]
        #expect(item.status == .interrupted(stage: stage))
        #expect(item.extractionState == (stage == .audioExtraction ? .paused : .completed))
        #expect(item.transcriptionState == (stage == .audioExtraction ? .waiting : stage == .transcription ? .paused : .completed))
        #expect(item.translationState == (stage == .translation ? .paused : .waiting))
        #expect(reopened.items[0].cues == processing.items[0].cues)
    }

    @Test func structuralEditsSurviveReloadWithoutRewritingRecognitionOrTranslationHistory() throws {
        var value = try task(translates: true)
        _ = try complete(&value, index: 0)
        _ = try complete(&value, index: 1)
        let ids = value.items[0].cues.map(\.id)
        let batch = try value.items[0].prepareTranslationBatch(cueIDs: ids)
        try value.items[0].beginTranslationBatch(batch)
        try value.items[0].commitTranslationBatch(batch, outputs: ids.map { .init(cueID: $0, text: "人工译文") })
        let history = value.items[0].checkpoint
        let original = value.items[0].cues
        let first = original[0]
        try value.items[0].splitSubtitle(comparedTo: first,
            atMilliseconds: (first.startMilliseconds + first.endMilliseconds) / 2,
            firstSourceText: "First", secondSourceText: "Second", firstTranslationText: "第一", secondTranslationText: "第二")
        #expect(value.items[0].cues.count == 3)
        #expect(!value.items[0].cues.contains { $0.id == first.id })
        try value.items[0].mergeSubtitles(comparedTo: Array(value.items[0].cues.prefix(2)),
            sourceText: "First Second", translationText: "第一，第二")
        try value.items[0].deleteSubtitles(comparedTo: [value.items[0].cues[1]])
        let added = try SubtitleCue(id: UUID(), startMilliseconds: 4400, endMilliseconds: 4800, sourceText: "Added")
        try value.items[0].insertSubtitle(added)
        #expect(value.items[0].status == .needsTranslation)
        let reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(value))
        #expect(reopened == value)
        #expect(reopened.items[0].checkpoint == history)
        #expect(try SubtitleExporter.generateSRT(cues: reopened.items[0].cues, kind: .source).contains("First Second"))
        try value.items[0].replaceSubtitles(original, comparedTo: value.items[0].cues)
        #expect(value.items[0].status == .completed)
        #expect(value.items[0].checkpoint == history)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(value)) == value)
    }

    @Test func deletedSubtitleRejectsLateTranslationAndRecoveryOnlyTargetsCurrentCues() throws {
        var value = try task(translates: true)
        _ = try complete(&value, index: 0)
        _ = try complete(&value, index: 1)
        let deleted = value.items[0].cues[0]
        let batch = try value.items[0].prepareTranslationBatch(cueIDs: [deleted.id])
        try value.items[0].beginTranslationBatch(batch)
        try value.items[0].deleteSubtitles(comparedTo: [deleted])
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(value)) == value)
        let before = value
        #expect(throws: CheckpointError.editedCue) {
            try value.items[0].commitTranslationBatch(batch, outputs: [.init(cueID: deleted.id, text: "Late")])
        }
        #expect(value == before)
        try value.items[0].recordTranslationFailure(batch, reason: "Subtitle deleted")
        var reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(value))
        let plan = try reopened.items[0].recoveryPlan(media: reopened.items[0].media!,
            parameters: reopened.parameters, ranges: ranges)
        #expect(plan.translationBatchIDs.isEmpty)
        #expect(plan.outdatedTranslationBatchIDs == [batch])
        #expect(plan.untranslatedCueIDs == reopened.items[0].cues.map(\.id))
        let fresh = try reopened.items[0].prepareTranslationBatch(cueIDs: plan.untranslatedCueIDs)
        try reopened.items[0].beginTranslationBatch(fresh)
        try reopened.items[0].commitTranslationBatch(fresh, outputs: plan.untranslatedCueIDs.map { .init(cueID: $0, text: "Current") })
        #expect(reopened.items[0].status == .completed)
        #expect(!reopened.items[0].cues.contains { $0.id == deleted.id })
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(reopened)) == reopened)
    }

    @Test func earlierRecognitionCanResumeAfterFollowingSubtitleWasReplaced() throws {
        var value = try task()
        _ = try complete(&value, index: 1)
        let following = value.items[0].cues[0]
        try value.items[0].splitSubtitle(comparedTo: following,
            atMilliseconds: (following.startMilliseconds + following.endMilliseconds) / 2,
            firstSourceText: "Manual first", secondSourceText: "Manual second", firstTranslationText: "", secondTranslationText: "")
        let manual = value.items[0].cues
        _ = try complete(&value, index: 0)
        #expect(value.items[0].cues.count == 3)
        #expect(Array(value.items[0].cues.suffix(2)) == manual)
        #expect(value.items[0].status == .completed)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(value)) == value)
    }

    @Test func invalidOrStaleTimelineEditsLeaveTheWholeTaskUntouched() throws {
        var value = try task()
        _ = try complete(&value, index: 0)
        _ = try complete(&value, index: 1)
        let original = value.items[0].cues[0]
        let before = value
        #expect(throws: DomainValidationError.invalidCue(original.id)) {
            try value.items[0].setSubtitleTiming(comparedTo: original, startMilliseconds: -1, endMilliseconds: 4000)
        }
        #expect(value == before)
        try value.items[0].setSubtitleTiming(comparedTo: original,
            startMilliseconds: original.startMilliseconds + 10, endMilliseconds: original.endMilliseconds + 10)
        let timed = value
        #expect(throws: CheckpointError.editedCue) {
            try value.items[0].deleteSubtitles(comparedTo: [original])
        }
        #expect(value == timed)
    }

    private let ranges = [TranscriptionChunkRange(sourceStartMilliseconds: 0, durationMilliseconds: 2000),
                          TranscriptionChunkRange(sourceStartMilliseconds: 2000, durationMilliseconds: 2000)]

    private func task(translates: Bool = false, apple: Bool = false) throws -> ProcessingTask {
        let media = try MediaIdentity(fileName: "sample.mp4", byteCount: 123, fingerprint: String(repeating: "a", count: 64),
                                      durationMilliseconds: 5000, audioTrackID: 1)
        let translation = apple ? try TranslationSettings(appleSourceLanguage: "en", targetLanguage: "zh-Hans", batchSize: 7) : translates ? try TranslationSettings(baseURL: URL(string: "https://example.test/v1")!,
            modelID: "model", targetLanguage: "zh-Hans", serviceID: UUID()) : nil
        let parameters = TaskParameters(transcription: .whisperKitBaseline, translation: translation)
        var task = ProcessingTask(items: [.init(title: "Sample", kind: .video,
            source: .localFile(fileName: media.fileName), media: media)], parameters: parameters)
        try task.recordStart()
        try task.items[0].initializeCheckpoint(parameters: parameters, ranges: ranges)
        return task
    }

    @Test func explicitCloudServiceRebindingPreservesCompletedRecognitionAndManualEdits() throws {
        let media = try MediaIdentity(fileName: "sample.mp4", byteCount: 123, fingerprint: String(repeating: "a", count: 64),
            durationMilliseconds: 5000, audioTrackID: 1)
        let first = TranscriptionSettings(provider: .openAICompatible, modelID: "gemini-test",
            cloud: .init(serviceID: UUID(), baseURL: URL(string: "https://first.example/v1")!, protocolKind: .geminiAudioChat))
        var task = ProcessingTask(items: [.init(title: "Sample", kind: .video,
            source: .localFile(fileName: media.fileName), media: media)], parameters: .init(transcription: first))
        try task.recordStart()
        try task.items[0].initializeCheckpoint(parameters: task.parameters, ranges: ranges)
        let chunk = task.items[0].checkpoint!.chunks[0]
        let sourceID = try task.items[0].beginTranscriptionChunk(chunk.id)
        var evidence = TranscriptionEvidence(settings: first, audio: try .init(localURL: URL(fileURLWithPath: "/tmp/test.wav"),
            sourceStartMilliseconds: 0, durationMilliseconds: 2000))
        evidence.cloudResult = .init(text: "Original.", segments: nil, timingSource: .audioRange)
        evidence = try CloudTranscriptionAlignment.completedEvidence(from: evidence)
        try task.items[0].commitTranscriptionChunk(chunk.id,
            result: SubtitleSegmenter.segment(evidence, sourceID: sourceID, mediaDurationMilliseconds: 5000))
        let before = task.items[0].cues[0]
        try task.items[0].editSubtitle(comparedTo: before, sourceText: "Manual.", translationText: "人工译文")
        let cues = task.items[0].cues
        let completed = task.items[0].checkpoint!.chunks[0]
        let second = TranscriptionSettings(provider: .openAICompatible, modelID: "qwen3-asr-flash",
            cloud: .init(serviceID: UUID(), baseURL: URL(string: "https://second.example/v1")!, protocolKind: .qwenAudioChat))
        try task.updateParameters(.init(transcription: second))
        #expect(task.items[0].cues == cues)
        #expect(task.items[0].checkpoint!.chunks[0] == completed)
        #expect(task.parameters.transcription == second)
        #expect(task.items[0].checkpoint?.parameters.transcription == second)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task)) == task)
        let alternatives: [TranscriptionSettings] = [
            .init(provider: .openAICompatible, modelID: "custom-asr", languageMode: .specified, languageCode: "ja",
                cloud: .init(serviceID: UUID(), baseURL: URL(string: "https://third.example/v1")!)),
            .init(modelID: "different-local-model", languageMode: .specified, languageCode: "en")
        ]
        for settings in alternatives {
            try task.updateParameters(.init(transcription: settings))
            #expect(task.items[0].cues == cues)
            #expect(task.items[0].checkpoint!.chunks[0] == completed)
            #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task)) == task)
        }
    }

    @Test func explicitTranslationEditsPreserveASRAndManualEditsAndRequireApprovalForANewTarget() throws {
        var original = try task(translates: true)
        _ = try complete(&original, index: 0)
        _ = try complete(&original, index: 1)
        let cue = original.items[0].cues[0]
        try original.items[0].editSubtitle(comparedTo: cue, sourceText: "Manual source", translationText: "手工校对")
        let pending = try original.items[0].prepareTranslationBatch(cueIDs: [original.items[0].cues[1].id])
        try original.items[0].beginTranslationBatch(pending)
        try original.items[0].recordTranslationFailure(pending, reason: "Unknown service")
        var conflictingParameters = original.parameters
        conflictingParameters.transcription = .init(modelID: "different-model")
        try original.updateParameters(conflictingParameters)
        #expect(original.parameters == conflictingParameters)
        let chunks = original.items[0].checkpoint!.chunks
        let cues = original.items[0].cues
        var parameters = original.parameters
        parameters.translation = try TranslationSettings(baseURL: URL(string: "https://new.example/v1")!,
            modelID: "new-model", targetLanguage: "zh-Hans", serviceID: UUID(), batchSize: 2)
        try original.updateParameters(parameters)
        #expect(original.items[0].cues == cues)
        #expect(original.items[0].checkpoint?.chunks == chunks)
        #expect(original.items[0].checkpoint?.translationBatches.isEmpty == true)
        #expect(original.items[0].checkpoint?.parameters == parameters)
        var reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(original))
        #expect(reopened == original)
        let ids = reopened.items[0].cues.map(\.id)
        let batch = try reopened.items[0].prepareTranslationBatch(cueIDs: [ids[1]])
        try reopened.items[0].beginTranslationBatch(batch)
        #expect(throws: CheckpointError.workRunning) { try reopened.updateParameters(parameters) }
        try reopened.items[0].commitTranslationBatch(batch, outputs: [.init(cueID: ids[1], text: "继续")])
        #expect(reopened.items[0].cues[0].translation == cues[0].translation)
        parameters.translation = try TranslationSettings(appleSourceLanguage: "en", targetLanguage: "ja")
        let before = reopened
        #expect(throws: TaskValidationError.translationReplacementRequired) { try reopened.updateParameters(parameters) }
        #expect(reopened == before)
        try reopened.updateParameters(parameters, discardingTranslations: true)
        #expect(reopened.items[0].cues.allSatisfy { $0.translation == .pending })
        #expect(reopened.items[0].cues.map(\.sourceText) == cues.map(\.sourceText))
        #expect(reopened.items[0].checkpoint?.chunks == chunks)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(reopened)) == reopened)
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
        #expect(task.items[0].status == .completed)
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
        let translated = task.items[0].cues[0]
        try task.items[0].editSubtitle(comparedTo: translated, sourceText: translated.sourceText, translationText: "")
        #expect(task.items[0].status == .needsTranslation)
        #expect(task.items[0].transcriptionState == .completed)
        #expect(task.items[0].translationState == .waiting)
        #expect(task.items[0].checkpoint == evidence)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task)) == task)
    }

    @Test func proofreadingRetainsFailureAndUnprocessedStates() throws {
        var task = try task()
        _ = try complete(&task, index: 0)
        _ = try complete(&task, index: 1)
        task.items[0].status = .needsTranslation
        let original = task.items[0].cues[0]
        try task.items[0].editSubtitle(comparedTo: original, sourceText: "Reviewed text", translationText: "")
        #expect(task.items[0].status == .completed)
        var unprocessed = task.items[0]
        unprocessed.checkpoint = nil
        unprocessed.status = .pending
        try unprocessed.editSubtitle(comparedTo: unprocessed.cues[0], sourceText: "Imported edit", translationText: "")
        #expect(unprocessed.status == .pending)
        task.items[0].status = .failed(reason: "Unresolved service failure")
        try task.items[0].editSubtitle(comparedTo: task.items[0].cues[0], sourceText: "Another edit", translationText: "")
        #expect(task.items[0].status == .failed(reason: "Unresolved service failure"))
    }

    @Test func recoveredTimingsCompleteAfterTranslationAndSurviveRestart() throws {
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
        try original.items[0].commitTranscriptionChunk(chunk.id, result: result)
        let batchID = try original.items[0].prepareTranslationBatch(cueIDs: original.items[0].cues.map(\.id))
        try original.items[0].beginTranslationBatch(batchID)
        try original.items[0].commitTranslationBatch(batchID, outputs: original.items[0].cues.map {
            TranslationBatchOutput(cueID: $0.id, text: "保留。")
        })
        #expect(original.items[0].status == .completed)
        let reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(original))
        #expect(reopened == original)
        #expect(reopened.items[0].status == .completed)
        #expect(reopened.items[0].checkpoint == original.items[0].checkpoint)
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(reopened)) == reopened)
    }

    @Test func restartSkipsCommittedChunksAndKeepsEditedCuesAndSource() throws {
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
        if case .completed(let saved) = record.chunks[0].state { #expect(saved.sourceID == result.sourceID) }
        else { Issue.record("Committed source missing") }
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
            fingerprint: record.media.fingerprint, durationMilliseconds: 5000, audioTrackID: 2)
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
        #expect(record.translationBatches[0].inputs.isEmpty)
        #expect(record.translationBatches[1].inputs.count == 1)
        let plan = try reopened.items[0].recoveryPlan(media: record.media, parameters: reopened.parameters, ranges: ranges)
        #expect(plan.transcriptionChunkIDs.isEmpty)
        #expect(plan.translationBatchIDs == [second])
        #expect(plan.untranslatedCueIDs.isEmpty)
        let firstCue = reopened.items[0].cues[0]
        try reopened.items[0].editSubtitle(comparedTo: firstCue, sourceText: firstCue.sourceText, translationText: "人工校对")
        try reopened.items[0].commitTranslationBatch(first, outputs: output)
        #expect(reopened.items[0].cues[0].translation == .succeeded(text: "人工校对", sourceRevision: 1))
        try reopened.items[0].beginTranslationBatch(second)
        try reopened.items[0].commitTranslationBatch(second, outputs: [.init(cueID: ids[1], text: "继续")])
        #expect(reopened.items[0].status == .completed)
        #expect(reopened.items[0].cues.allSatisfy { $0.hasTranslation })
        try reopened.items[0].cues[0].replaceSourceText(with: "Edited again")
        let edited = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(reopened))
        #expect(edited.items[0].cues[0].translation == .succeeded(text: "人工校对", sourceRevision: 1))
        #expect(edited.items[0].cues[0].hasTranslation)
        #expect(try edited.items[0].recoveryPlan(media: record.media, parameters: edited.parameters, ranges: ranges).untranslatedCueIDs.isEmpty)
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
        let workIndex = try TranslationCheckpointIndex(item: task.items[0])
        try task.items[0].beginTranslationBatch(second, using: workIndex)
        task.items[0].cues[1].startMilliseconds += 50
        task.items[0].cues[1].endMilliseconds += 50
        let inserted = try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 100, sourceText: "Manual introduction")
        task.items[0].cues.insert(inserted, at: 0)
        try task.items[0].commitTranslationBatch(second, outputs: [.init(cueID: ids[1], text: "Success")], using: workIndex)
        #expect(task.items[0].cues.first == inserted)
        #expect(task.items[0].status == .failed(reason: "Service failure"))
        #expect(task.items[0].cues[2].startMilliseconds == 2250)
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
        let invalid = SubtitleSegmentationResult(sourceID: sourceID, evidence: candidate.evidence,
            policy: candidate.policy, entries: [], excludedEmptySegmentIndices: [])
        #expect(throws: CheckpointError.invalidRecord) { try task.items[0].commitTranscriptionChunk(next.id, result: invalid) }
        #expect(task == edited)
        try task.items[0].commitTranscriptionChunk(next.id, result: candidate)
        #expect(task.items[0].cues[0] == edited.items[0].cues[0])
        #expect(task.items[0].cues[1] == candidate.cues[0])
        #expect(try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task)) == task)
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
        try task.recordStart()
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
