import Foundation
import Testing
import VoxlineCore
import VoxlineMedia
import VoxlineTranslation
@testable import VoxlineWorkflow

@Suite("Imported subtitles use the existing queue", .serialized)
@MainActor
struct ImportedSubtitleQueueTests {
    @Test func restartResumesOnlyTranslationAndPreservesImportedAndManualText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = try MediaIdentity(fileName: "source.mp4", byteCount: 123, fingerprint: String(repeating: "a", count: 64), durationMilliseconds: 5000, audioTrackID: 1)
        let item = TaskMediaItem(title: "source", kind: .video, source: .localFile(fileName: media.fileName), media: media)
        let settings = try TranslationSettings(baseURL: URL(string: "https://test.example/v1")!, modelID: "model", targetLanguage: "zh-Hans", serviceID: UUID(), batchSize: 1)
        var task = ProcessingTask(items: [item], parameters: .init(transcription: .whisperKitBaseline, translation: settings))
        let original = try SubtitleImporter.parse("1\n00:00:00,000 --> 00:00:02,000\nFirst\n\n2\n00:00:01,000 --> 00:00:03,000\nSecond", format: .srt)
        try task.importOriginalSubtitles(mediaID: item.id, entries: original, origin: .file(name: "source.srt"), comparedTo: item)
        let library = TaskLibrary(tasksDirectory: directory)
        try library.save(task)
        let transcription = ForbiddenRecognition()
        let failing = ImportTranslation(failSecond: true)
        let queue = TaskProcessingQueue(library: library, pipeline: transcription, translationPipeline: failing)
        try queue.start(taskID: task.id)
        await queue.waitUntilIdle()
        let failed = try #require(library.task(for: task.id))
        #expect(failed.items[0].cues[0].hasTranslation && !failed.items[0].cues[1].hasTranslation)
        #expect(failed.items[0].checkpoint?.chunks.isEmpty == true)
        let reopened = TaskLibrary(tasksDirectory: directory)
        try reopened.commitCheckpoint(taskID: task.id) { task in
            let cue = task.items[0].cues[0]
            try task.items[0].editSubtitle(comparedTo: cue, sourceText: cue.sourceText, translationText: "人工译文")
        }
        let success = ImportTranslation(failSecond: false)
        let resumed = TaskProcessingQueue(library: reopened, pipeline: transcription, translationPipeline: success)
        try resumed.start(taskID: task.id)
        await resumed.waitUntilIdle()
        let saved = try TaskDocumentCodec.decode(Data(contentsOf: reopened.defaultURL(for: task.id)))
        #expect(saved.status == .completed)
        #expect(saved.items[0].cues.map(\.sourceText) == ["First", "Second"])
        #expect(saved.items[0].cues[0].translation == .succeeded(text: "人工译文", sourceRevision: 1))
        #expect(await success.cueIDs == [original[1].id])
        #expect(await transcription.calls == 0)
        try resumed.startRetranslation(taskID: task.id, mediaID: item.id, cueIDs: [original[1].id])
        await resumed.waitUntilIdle()
        #expect(await transcription.calls == 0)
    }
}

private actor ForbiddenRecognition: MediaTranscriptionPipeline {
    var calls = 0
    func extract(item: TaskMediaItem, progress: @escaping @Sendable (AudioExtractionProgress) -> Void) async throws -> [TranscriptionAudio] {
        calls += 1; throw CheckpointError.incompleteWork
    }
    func transcribe(mediaID: UUID, audio: TranscriptionAudio, settings: TranscriptionSettings,
                    progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> TranscriptionEvidence {
        calls += 1; throw CheckpointError.incompleteWork
    }
}

private actor ImportTranslation: SubtitleTranslationPipeline {
    let failSecond: Bool
    var cueIDs: [UUID] = []
    init(failSecond: Bool) { self.failSecond = failSecond }
    func translate(settings: TranslationSettings, request: SubtitleTranslationRequest) async throws -> [TranslationBatchOutput] {
        cueIDs.append(contentsOf: request.inputs.map(\.cueID))
        if failSecond, cueIDs.count == 2 { throw SubtitleTranslationError.invalidResponse }
        return request.inputs.map { .init(cueID: $0.cueID, text: "译文 " + $0.sourceText) }
    }
}
