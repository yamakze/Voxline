import Foundation
import Testing
@testable import VoxlineCore

@Suite("Task documents and parameter snapshots")
struct ProcessingTaskTests {
    @Test func failedInputDoesNotBlockHealthyMediaOrEraseExistingCues() throws {
        var healthy = try associatedItem(kind: .audio, name: "lecture.wav")
        healthy.cues = [try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 500, sourceText: "Keep")]
        let failed = TaskMediaItem(title: "Broken", kind: .video, source: .localFile(fileName: "broken.mov"),
                                   status: .failed(reason: "Empty file"))
        var task = ProcessingTask(items: [failed, healthy])
        try task.freezeParameters()
        let reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task))
        #expect(reopened.items == [failed, healthy])
        #expect(reopened.startedAt != nil)
        #expect(reopened.completedCount == 0)
        var unusable = ProcessingTask(items: [failed])
        #expect(throws: TaskValidationError.noReadyMedia) { try unusable.freezeParameters() }
        #expect(unusable.startedAt == nil)
    }

    @Test func orderedAudioAndVideoKeepIndependentResultsAcrossSave() throws {
        var first = try associatedItem(kind: .audio, name: "lecture.wav")
        var second = try associatedItem(kind: .video, name: "movie.mp4")
        first.cues = [try SubtitleCue(id: UUID(), startMilliseconds: 100, endMilliseconds: 700, sourceText: "First")]
        second.cues = [try SubtitleCue(id: UUID(), startMilliseconds: 800, endMilliseconds: 1600, sourceText: "Second")]
        var task = ProcessingTask(title: "Batch", items: [first, second])
        try task.freezeParameters()
        task.items[0].status = .completed
        task.items[1].status = .failed(reason: "Service unavailable")
        let reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task))
        #expect(reopened == task)
        #expect(reopened.items.map(\.id) == [first.id, second.id])
        #expect(reopened.items[0].cues == first.cues)
        #expect(reopened.items[1].cues == second.cues)
        #expect(reopened.completedCount == 1)
        #expect(reopened.failedCount == 1)
        #expect(reopened.status == .partiallyFailed)
    }

    @Test func explicitEditsBeforeTranscriptionPreserveServiceSnapshotAndStartTime() throws {
        let serviceID = UUID()
        let translation = try TranslationSettings(baseURL: URL(string: "https://example.test/v1")!,
                                                   modelID: "selected-model", targetLanguage: "zh-Hans", serviceID: serviceID, batchSize: 7, systemPrompt: "Keep a conversational style.")
        var parameters = TaskParameters(transcription: TranscriptionSettings(modelID: "selected-whisper",
                                          languageMode: .specified, languageCode: "en"),
                                        translation: translation)
        var task = ProcessingTask(items: [try associatedItem()], parameters: parameters)
        let startedAt = Date(timeIntervalSince1970: 1_000)
        try task.freezeParameters(at: startedAt)
        #expect(task.status == .queued)
        parameters.transcription = .whisperKitBaseline
        try task.updateParameters(parameters)
        #expect(task.parameters.transcription == .whisperKitBaseline)
        var reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task))
        #expect(reopened.startedAt == startedAt)
        #expect(reopened.parameters == task.parameters)
        #expect(reopened.parameters.translation?.api?.serviceID == serviceID)
        #expect(throws: TaskValidationError.parametersFrozen) { try reopened.freezeParameters() }
        let json = try #require(String(data: TaskDocumentCodec.encode(reopened), encoding: .utf8))
        #expect(!json.contains("apiKey"))
        #expect(!json.contains("bookmark"))
    }




    @Test func interruptedWorkKeepsAlreadyCommittedResults() throws {
        var task = ProcessingTask(items: [try associatedItem(), try associatedItem()])
        try task.freezeParameters()
        task.items[0].status = .completed
        task.items[1].status = .running(stage: .translation)
        task.items[1].cues = [try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 500, sourceText: "Keep")]
        var reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task))
        reopened.interruptRunningItems()
        #expect(reopened.items[0] == task.items[0])
        #expect(reopened.items[1].status == .interrupted(stage: .translation))
        #expect(reopened.items[1].cues == task.items[1].cues)
        #expect(reopened.status == .interrupted)
    }

    @Test func corruptedUnknownAndMalformedTasksAreExplicitErrors() throws {
        #expect(throws: ProjectValidationError.unsupportedVersion(99)) {
            try TaskDocumentCodec.decode(Data(#"{"formatVersion":99,"unknown":true}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try TaskDocumentCodec.decode(Data(#"{"formatVersion":2,"id":"truncated""#.utf8))
        }
        var task = ProcessingTask(items: [try associatedItem()])
        task.items[0].status = .completed
        #expect(throws: TaskValidationError.workBeforeStart(task.items[0].id)) { try TaskDocumentCodec.encode(task) }
        task.items[0].status = .failed(reason: " ")
        #expect(throws: TaskValidationError.emptyFailureReason(task.items[0].id)) { try TaskDocumentCodec.encode(task) }
    }

    @Test func invalidDraftParametersDoNotReplaceTheLastSelection() throws {
        var task = ProcessingTask()
        var parameters = task.parameters
        parameters.transcription = .init(modelID: "")
        #expect(throws: ProjectValidationError.emptyModelID) { try task.updateParameters(parameters) }
        #expect(task.parameters == .baseline)
        #expect(throws: ProjectValidationError.invalidSourceLanguage) {
            try TranscriptionSettings(modelID: "model", languageMode: .specified).validate()
        }
    }

    @Test func noExecutionSnapshotCanBeCreatedWithoutRealMediaOrAConfiguredService() throws {
        var empty = ProcessingTask()
        #expect(throws: TaskValidationError.noMedia) { try empty.freezeParameters() }
        var unassociated = ProcessingTask(items: [TaskMediaItem(title: "File", kind: .video, source: .unassociated)])
        #expect(throws: TaskValidationError.unassociatedMedia(unassociated.items[0].id)) { try unassociated.freezeParameters() }
        let translation = try TranslationSettings(baseURL: URL(string: "https://example.test/v1")!,
                                                   modelID: "model", targetLanguage: "zh-Hans")
        var task = ProcessingTask(items: [try associatedItem()],
                                  parameters: TaskParameters(transcription: .whisperKitBaseline, translation: translation))
        #expect(throws: TaskValidationError.unconfiguredTranslationService) { try task.freezeParameters() }
        #expect(task.startedAt == nil)
    }

    private func associatedItem(kind: TaskMediaKind = .video, name: String = "sample.mp4") throws -> TaskMediaItem {
        let identity = try MediaIdentity(fileName: name, byteCount: 123, fingerprint: String(repeating: "a", count: 64),
                                         durationMilliseconds: 5000, audioTrackID: 1)
        return TaskMediaItem(title: name, kind: kind, source: .localFile(fileName: name), media: identity)
    }
}
