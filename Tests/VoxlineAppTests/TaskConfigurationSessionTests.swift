import AVFoundation
import Foundation
import Testing
import VoxlineCore
import VoxlineMedia
import VoxlineWorkflow
@testable import VoxlineApp

@Suite("Task preparation commits", .serialized, .timeLimit(.minutes(1))) @MainActor
struct TaskConfigurationSessionTests {
    @Test func failedSaveRetainsParametersAndManualSubtitlesForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var cue = try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 1000, sourceText: "Manual source")
        cue.translation = .succeeded(text: "人工译文", sourceRevision: cue.sourceRevision)
        let item = TaskMediaItem(title: "Edited", kind: .audio, source: .unassociated, cues: [cue])
        let task = ProcessingTask(title: "Before", items: [item])
        let library = TaskLibrary(tasksDirectory: root)
        try library.save(task)
        let session = TaskConfigurationSession(task: task)
        session.draftTitle = "After"
        session.modelID = "openai_whisper-tiny"
        let file = library.defaultURL(for: task.id)
        let backup = root.appendingPathComponent("last-saved")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await session.commit(comparedTo: { task }) { try library.save($0) }
        }
        #expect(library.task(for: task.id) == task)
        #expect(session.draftTitle == "After" && session.modelID == "openai_whisper-tiny")
        #expect(!session.isSaving && session.existingItems == [item])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let saved = try await session.commit(comparedTo: { task }) { try library.save($0) }
        let reopened = try TaskDocumentCodec.decode(Data(contentsOf: file))
        #expect(reopened == saved)
        #expect(reopened.title == "After" && reopened.parameters.transcription.modelID == session.modelID)
        #expect(reopened.items == [item])
    }

    @Test func nativeMediaPreparationPersistsAccessAndIsolatesBrokenInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("speech.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = buffer.frameCapacity
        try #require(buffer.floatChannelData?[0]).update(repeating: 0.125, count: Int(buffer.frameLength))
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            try writer.write(from: buffer)
        }
        let broken = root.appendingPathComponent("broken.mp4")
        try Data().write(to: broken)
        let task = ProcessingTask(title: "Prepare media")
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("tasks"))
        let mediaStore = LocalMediaStore(directory: root.appendingPathComponent("associations"))
        let session = TaskConfigurationSession(task: task, mediaStore: mediaStore)
        session.importMediaURLs([url, broken])
        while session.isInspecting { try await Task.sleep(for: .milliseconds(10)) }
        let saved = try await session.commit(comparedTo: { task }) { try library.save($0) }
        let item = try #require(saved.items.first)
        let identity = try #require(item.media)
        let bookmark = try #require(try await mediaStore.resolve(mediaID: item.id, identity: identity))
        #expect(bookmark.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
        #expect(identity.durationMilliseconds == 1000 && identity.audioTrackID == 1)
        #expect(saved.items.count == 2 && saved.items[1].media == nil)
        guard case .failed(let reason) = saved.items[1].status else { Issue.record("Broken input became usable"); return }
        #expect(!reason.isEmpty)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id))) == saved)
    }

    @Test func editDuringLanguagePreparationCannotBeOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = ProcessingTask(title: "Original")
        let library = TaskLibrary(tasksDirectory: root)
        try library.save(task)
        let session = TaskConfigurationSession(task: task, prepareLanguages: { _, _ in
            var edited = task
            edited.title = "Newer edit"
            try library.save(edited)
        })
        session.translates = true
        session.translationEngine = .apple
        await #expect(throws: TaskValidationError.taskChanged) {
            try await session.commit(comparedTo: { library.task(for: task.id)! }) { try library.save($0) }
        }
        #expect(!session.isSaving && session.translates)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: library.defaultURL(for: task.id))).title == "Newer edit")
    }
}
