import Foundation
import Testing
import VoxlineCore
import VoxlineMedia
import VoxlineWorkflow
@testable import VoxlineApp

@Suite("Subtitle import preparation", .serialized)
@MainActor
struct SubtitleImportSessionTests {
    @Test func fileDraftCommitsWithoutASRConfigurationAndNoLongerNeedsItsOriginalFile() async throws {
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
        let preparation = TaskConfigurationSession(task: task)
        #expect(TaskConfigurationSession(task: ProcessingTask()).requiresSpeechRecognition)
        preparation.transcriptionProvider = .openAICompatible
        preparation.selectedCloudServiceID = nil
        preparation.subtitleImports[item.id] = try importing.originalSelection()
        #expect(!preparation.requiresSpeechRecognition && preparation.preflightBlockReason == nil)
        let library = TaskLibrary(tasksDirectory: directory.appendingPathComponent("tasks"))
        let saved = try await preparation.commit(comparedTo: { task }) { try library.save($0) }
        try FileManager.default.removeItem(at: file)
        let reopened = try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id)))
        #expect(reopened == saved)
        #expect(reopened.items[0].status == .completed && reopened.items[0].checkpoint?.chunks.isEmpty == true)
        #expect(reopened.items[0].cues.map(\.sourceText) == ["Imported", "Concurrent"])
        #expect(reopened.items[0].cues.map(\.endMilliseconds) == [800, 600])
        let reset = TaskConfigurationSession(task: reopened)
        reset.speechRecognitionSelections.insert(item.id)
        #expect(reset.requiresSpeechRecognition)
        let resetTask = try await reset.commit(comparedTo: { reopened }) { try library.save($0) }
        #expect(resetTask.items[0].cues.isEmpty && resetTask.items[0].importedSubtitleOrigin == nil)
        #expect(resetTask.items[0].checkpoint == nil && resetTask.items[0].status == .pending)

        try "1\n00:00:01,000 --> 00:00:00,500\nInvalid".write(to: file, atomically: true, encoding: .utf8)
        await importing.readFile(file)
        #expect(importing.errorMessage != nil && importing.entries.isEmpty && importing.origin == nil)
        #expect(library.task(for: task.id) == resetTask)
    }

    @Test func singleEmbeddedTrackIsReadWithoutAnAdditionalPickerChange() async throws {
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
        let session = SubtitleImportSession(item: item, role: .original, mediaURL: output)
        await session.loadEmbeddedTracks()
        #expect(session.errorMessage == nil && session.tracks.count == 1)
        let selection = try session.originalSelection()
        #expect(selection.entries.map(\.text) == ["Embedded"])
        #expect(selection.origin == .embedded(trackID: try #require(session.selectedTrackID), language: "en"))
    }
}
