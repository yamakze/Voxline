import Foundation
import Testing
import VoxlineCore
@testable import VoxlineApp

@Suite("Task persistence after UI refactoring", .serialized)
@MainActor
struct TaskLibraryTests {
    @Test func openingLegacyTaskDoesNotRewriteOriginalAndFailedSaveKeepsLastDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.voxline")
        let legacy = SubtitleProject()
        let original = try ProjectDocumentCodec.encode(legacy)
        try original.write(to: url)
        let library = TaskLibrary(tasksDirectory: directory)
        var migrated = try TaskDocumentCodec.decode(original)
        library.register(migrated, at: url)
        #expect(try Data(contentsOf: url) == original)
        migrated.title = "Saved migration"
        try library.save(migrated)
        let lastSaved = try Data(contentsOf: url)
        migrated.title = " "
        #expect(throws: TaskValidationError.emptyTitle) { try library.save(migrated) }
        #expect(try Data(contentsOf: url) == lastSaved)
        #expect(library.task(for: migrated.id)?.title == "Saved migration")
        let reopened = TaskLibrary(tasksDirectory: directory)
        #expect(reopened.task(for: migrated.id)?.title == "Saved migration")
    }

    @Test func corruptTasksAndWriteFailuresRemainExplicit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corruptURL = directory.appendingPathComponent("broken.voxline")
        try Data("invalid".utf8).write(to: corruptURL)
        let library = TaskLibrary(tasksDirectory: directory)
        let entry = try #require(library.entries.first {
            $0.url?.resolvingSymlinksInPath().path == corruptURL.resolvingSymlinksInPath().path
        })
        #expect(entry.task == nil)
        #expect(entry.error != nil)
        let task = ProcessingTask()
        let blocked = directory.appendingPathComponent("occupied.voxline")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try library.save(task, at: blocked) }
        #expect(library.task(for: task.id) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: blocked.path).isEmpty)
    }

    @Test func checkpointCommitUsesLatestUnsavedEditsAndWriteFailureDoesNotPublishResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = TaskLibrary(tasksDirectory: directory)
        let media = try MediaIdentity(fileName: "sample.wav", byteCount: 42, sha256: String(repeating: "a", count: 64),
            durationMilliseconds: 5000, audioTrackID: 1)
        var task = ProcessingTask(items: [.init(title: "Sample", kind: .audio, source: .localFile(fileName: media.fileName), media: media)])
        try task.freezeParameters()
        try task.items[0].initializeCheckpoint(parameters: task.parameters, ranges: [
            .init(sourceStartMilliseconds: 0, durationMilliseconds: 2000),
            .init(sourceStartMilliseconds: 2000, durationMilliseconds: 2000)])
        try library.save(task)
        let url = try #require(library.url(for: task.id))
        let chunks = try #require(task.items[0].checkpoint?.chunks)
        func result(index: Int, sourceID: UUID) throws -> SubtitleSegmentationResult {
            let range = chunks[index].range
            let audio = try TranscriptionAudio(localURL: URL(fileURLWithPath: "/tmp/fixture.wav"),
                sourceStartMilliseconds: range.sourceStartMilliseconds, durationMilliseconds: range.durationMilliseconds)
            var evidence = TranscriptionEvidence(settings: task.parameters.transcription, audio: audio)
            evidence.outcome = .completed
            evidence.segments = [.init(startSeconds: Double(range.sourceStartMilliseconds) / 1000,
                endSeconds: Double(range.sourceStartMilliseconds) / 1000 + 0.5, text: "Original", words: nil)]
            return try SubtitleSegmenter.segment(evidence, sourceID: sourceID, mediaDurationMilliseconds: 5000)
        }
        let firstID = try library.commitCheckpoint(taskID: task.id) {
            try $0.items[0].beginTranscriptionChunk(chunks[0].id)
        }
        let first = try result(index: 0, sourceID: firstID)
        try library.commitCheckpoint(taskID: task.id) { try $0.items[0].commitTranscriptionChunk(chunks[0].id, result: first) }
        let secondID = try library.commitCheckpoint(taskID: task.id) {
            try $0.items[0].beginTranscriptionChunk(chunks[1].id)
        }
        var edited = try #require(library.task(for: task.id))
        try edited.items[0].cues[0].replaceSourceText(with: "Unsaved manual correction")
        let previousFile = try Data(contentsOf: url)
        let blocked = directory.appendingPathComponent("occupied.voxline")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        library.register(edited, at: blocked)
        let second = try result(index: 1, sourceID: secondID)
        #expect(throws: (any Error).self) {
            try library.commitCheckpoint(taskID: task.id) { try $0.items[0].commitTranscriptionChunk(chunks[1].id, result: second) }
        }
        #expect(library.task(for: task.id) == edited)
        #expect(try Data(contentsOf: url) == previousFile)
        #expect(try FileManager.default.contentsOfDirectory(atPath: blocked.path).isEmpty)
        library.register(edited, at: url)
        try library.commitCheckpoint(taskID: task.id) { try $0.items[0].commitTranscriptionChunk(chunks[1].id, result: second) }
        let reopened = try TaskDocumentCodec.decode(Data(contentsOf: url))
        #expect(reopened.items[0].status == .completed)
        #expect(reopened.items[0].cues.count == 2)
        #expect(reopened.items[0].cues[0].sourceText == "Unsaved manual correction")
        #expect(reopened.items[0].cues[0].sourceRevision == 2)
        if case .completed(let original) = reopened.items[0].checkpoint?.chunks[0].state {
            #expect(original == first)
        } else { Issue.record("Raw result was lost") }
        #expect(TaskLibrary(tasksDirectory: directory).task(for: task.id)?.items[0] == reopened.items[0])
        #expect(throws: CheckpointError.taskUnavailable) {
            try library.commitCheckpoint(taskID: UUID()) { $0.title = "Cannot apply" }
        }
    }
}
