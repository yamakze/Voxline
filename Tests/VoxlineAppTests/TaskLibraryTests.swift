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
}
