import Foundation
import Testing
import VoxlineCore
import VoxlineMedia
import VoxlineWorkflow
@testable import VoxlineApp

@Suite("Subtitle import preparation", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SubtitleImportSessionTests {
    @Test func externalImportPersistsWithoutItsOriginalFileAndFailedReadingKeepsTheSavedTask() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.vtt")
        try "WEBVTT\n\n00:00.000 --> 00:00.800\nImported\n\n00:00.200 --> 00:00.600\nConcurrent".write(to: file, atomically: true, encoding: .utf8)
        let media = try MediaIdentity(fileName: "clip.mp4", byteCount: 123, fingerprint: String(repeating: "a", count: 64), durationMilliseconds: 1000, audioTrackID: 1)
        let item = TaskMediaItem(title: "clip", kind: .video, source: .localFile(fileName: media.fileName), media: media)
        let task = ProcessingTask(items: [item])
        let importing = SubtitleImportSession(item: item, role: .original)
        await importing.readFile(file)
        #expect(importing.errorMessage == nil)
        let library = TaskLibrary(tasksDirectory: directory.appendingPathComponent("tasks"))
        try library.save(task)
        try library.importOriginalSubtitles(importing.originalSelection(), taskID: task.id, comparedTo: item)
        try FileManager.default.removeItem(at: file)
        let reopened = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        #expect(reopened == library.task(for: task.id))
        #expect(reopened.items[0].status == .completed && reopened.items[0].checkpoint?.chunks.isEmpty == true)
        #expect(reopened.items[0].cues.map(\.sourceText) == ["Imported", "Concurrent"])
        #expect(reopened.items[0].cues.map(\.endMilliseconds) == [800, 600])
        try "1\n00:00:01,000 --> 00:00:00,500\nInvalid".write(to: file, atomically: true, encoding: .utf8)
        await importing.readFile(file)
        #expect(importing.errorMessage != nil && importing.entries.isEmpty && importing.origin == nil)
        #expect(library.task(for: task.id) == reopened)
    }

    @Test func addingVideoAutomaticallyImportsTextAndVideoWithoutSubtitlesKeepsASR() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("VoxlineMediaTests/Fixtures/multi-audio.mov")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inspector = MediaInspector()
        let inspection = try await inspector.inspect(source)
        let media = try inspection.identity(audioTrackID: #require(inspection.audioTracks.first).id)
        let cue = try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 800, sourceText: "Embedded")
        let item = TaskMediaItem(title: "clip", kind: .video, source: .localFile(fileName: media.fileName), media: media, cues: [cue])
        let store = LocalMediaStore(directory: directory.appendingPathComponent("bookmarks"))
        try await store.save(mediaID: item.id, identity: media, url: source)
        let output = directory.appendingPathComponent("embedded.mp4")
        try await SubtitleEmbeddingExporter.export(item: item, kind: .source, to: output, languageTag: "en", mediaStore: store, inspector: inspector)
        let task = ProcessingTask()
        let preparation = TaskConfigurationSession(task: task, inspector: inspector, mediaStore: store)
        preparation.importMediaURLs([output])
        while preparation.isInspecting { await Task.yield() }
        #expect(preparation.candidates.count == 1 && preparation.candidates[0].error == nil)
        #expect(!preparation.requiresSpeechRecognition)
        preparation.transcriptionProvider = .openAICompatible
        preparation.selectedCloudServiceID = nil
        let library = TaskLibrary(tasksDirectory: directory.appendingPathComponent("tasks"))
        let saved = try await preparation.commit(comparedTo: { task }) { try library.save($0) }
        #expect(saved.items[0].cues.map(\.sourceText) == ["Embedded"])
        #expect(saved.items[0].importedSubtitleOrigin != nil && saved.items[0].status == .completed)
        #expect(saved.items[0].checkpoint?.chunks.isEmpty == true)

        preparation.importMediaURLs([source])
        while preparation.isInspecting { await Task.yield() }
        #expect(preparation.requiresSpeechRecognition && preparation.candidates[1].error == nil)
        #expect(preparation.subtitleImports.count == 1)
    }
}
