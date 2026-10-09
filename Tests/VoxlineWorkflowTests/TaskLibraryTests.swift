import Foundation
import Testing
import VoxlineCore
@testable import VoxlineWorkflow

@Suite("Task document persistence", .serialized)
@MainActor
struct TaskLibraryTests {
    @Test func deletionRetainsSameIDCopiesAndMigratedMediaUntilLastKnownReference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("tasks")
        let support = root.appendingPathComponent("support")
        let caches = root.appendingPathComponent("caches")
        let mediaID = UUID() // A migrated project keeps this ID across copies and tasks.
        let task = ProcessingTask(title: "Migrated", items: [.init(id: mediaID, title: "Media", kind: .audio, source: .unassociated)])
        let copy = root.appendingPathComponent("external.voxline")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try TaskDocumentCodec.encode(task).write(to: copy)
        var recent = [copy]
        let library = TaskLibrary(tasksDirectory: local, recentDocumentURLs: { recent },
            forgetRecentDocument: { url in recent.removeAll { $0 == url } },
            resourceCleanup: .init(applicationSupport: support, caches: caches))
        try library.save(task, at: library.defaultURL(for: task.id))
        let paths = [support.appendingPathComponent("Voxline/MediaAssociations/\(mediaID).json"),
                     caches.appendingPathComponent("Voxline/Audio/\(mediaID)/000000.wav"),
                     caches.appendingPathComponent("Voxline/Transcription/\(mediaID)/record.json")]
        for path in paths {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Device artifact".utf8).write(to: path)
        }
        let untouched = root.appendingPathComponent("source.wav")
        try Data("Original source".utf8).write(to: untouched)
        try library.reorder(entryIDs: library.entries.map(\.id))
        try library.delete(taskID: task.id)
        #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: copy.path))
        let order = try JSONDecoder().decode([URL].self, from: Data(contentsOf: local.appendingPathComponent("task-order.json")))
        #expect(!order.contains(library.defaultURL(for: task.id)))
        library.refresh()
        #expect(library.task(for: task.id) == task) // The separate copy still exists.
        try library.delete(taskID: task.id)
        #expect(recent.isEmpty)
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: untouched) == Data("Original source".utf8))
        #expect(TaskLibrary(tasksDirectory: local, recentDocumentURLs: { recent }).entries.isEmpty)
    }

    @Test func cacheCleanupFailureDoesNotRestoreDeletedTask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let caches = root.appendingPathComponent("caches")
        let tasks = root.appendingPathComponent("tasks")
        let cleanup = TaskResourceCleanup(applicationSupport: support, caches: caches)
        let task = ProcessingTask(items: [.init(title: "Media", kind: .audio, source: .unassociated)])
        let library = TaskLibrary(tasksDirectory: tasks, resourceCleanup: cleanup)
        try library.save(task)
        let id = task.items[0].id
        let audio = caches.appendingPathComponent("Voxline/Audio/\(id)")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let associations = support.appendingPathComponent("Voxline/MediaAssociations")
        try FileManager.default.createDirectory(at: associations, withIntermediateDirectories: true)
        let record = associations.appendingPathComponent("\(id).json")
        try Data("Blocked record".utf8).write(to: record)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: associations.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: associations.path) }
        try library.delete(taskID: task.id)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(library.task(for: task.id) == nil)
        #expect(library.errorMessage?.contains(record.path) == true)
        #expect(TaskLibrary(tasksDirectory: tasks, resourceCleanup: cleanup).task(for: task.id) == nil)

    }

    @Test func corruptHistoricalCacheAndUnreadableOtherTaskDoNotBlockDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let caches = root.appendingPathComponent("caches")
        let transcription = caches.appendingPathComponent("Voxline/Transcription")
        try FileManager.default.createDirectory(at: transcription, withIntermediateDirectories: true)
        let historical = transcription.appendingPathComponent("old.json")
        try Data("broken evidence".utf8).write(to: historical)
        let library = TaskLibrary(tasksDirectory: root.appendingPathComponent("tasks"),
            resourceCleanup: .init(applicationSupport: root, caches: caches))
        let task = ProcessingTask(items: [.init(title: "Audio", kind: .audio, source: .unassociated)])
        try library.save(task)
        let owned = transcription.appendingPathComponent(task.items[0].id.uuidString)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try Data("broken owned evidence".utf8).write(to: owned.appendingPathComponent("record.json"))
        try library.delete(taskID: task.id)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: historical.path))

        let another = ProcessingTask(items: [.init(title: "Audio", kind: .audio, source: .unassociated)])
        try library.save(another)
        let brokenTask = library.tasksDirectory.appendingPathComponent("broken.voxline")
        try Data("unknown task references".utf8).write(to: brokenTask)
        library.refresh()
        let retainedCache = transcription.appendingPathComponent(another.items[0].id.uuidString)
        try FileManager.default.createDirectory(at: retainedCache, withIntermediateDirectories: true)
        try library.delete(taskID: another.id)
        #expect(library.task(for: another.id) == nil)
        #expect(FileManager.default.fileExists(atPath: retainedCache.path))
        #expect(library.errorMessage?.contains(brokenTask.path) == true)
    }

    @Test func listOrderSurvivesWorkerSavesAndRestartAndDeletionDoesNotTouchMedia() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("source.mp4")
        try Data("Source stays".utf8).write(to: media)
        let first = ProcessingTask(title: "First")
        let second = ProcessingTask(title: "Second")
        let library = TaskLibrary(tasksDirectory: directory)
        try library.save(first)
        try library.save(second)
        try library.move(entryID: first.id.uuidString, to: second.id.uuidString)
        #expect(library.entries.map(\.taskID) == [first.id, second.id])
        try library.save(first)
        #expect(library.entries.map(\.taskID) == [first.id, second.id])
        let recent = library.defaultURL(for: second.id)
        let reopened = TaskLibrary(tasksDirectory: directory, recentDocumentURLs: { [recent] })
        #expect(reopened.entries.map(\.taskID) == [first.id, second.id])
        try reopened.delete(taskID: second.id)
        reopened.refresh()
        #expect(reopened.entries.map(\.taskID) == [first.id])
        #expect(try Data(contentsOf: media) == Data("Source stays".utf8))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("task-order.json"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("task-order.json"), withIntermediateDirectories: false)
        let before = reopened.entries.map(\.id)
        #expect(throws: (any Error).self) { try reopened.reorder(entryIDs: before) }
        #expect(reopened.entries.map(\.id) == before)
    }

    @Test func nativeRecentDocumentsAreReadWithoutRewritingAndRegistrationIsSeparateFromSaving() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.appendingPathComponent("external.voxline")
        let broken = directory.appendingPathComponent("broken.voxline")
        let task = ProcessingTask(title: "External task")
        let original = try TaskDocumentCodec.encode(task)
        try original.write(to: external)
        try Data("broken".utf8).write(to: broken)
        var noted: [URL] = []
        let library = TaskLibrary(tasksDirectory: directory.appendingPathComponent("local"),
            recentDocumentURLs: { [external, external, broken] }, noteRecentDocument: { noted.append($0) })
        #expect(library.entries.count == 2)
        #expect(library.task(for: task.id) == task)
        #expect(library.entries.contains { $0.url == broken && $0.error != nil })
        #expect(noted.isEmpty)
        #expect(try Data(contentsOf: external) == original)
        library.register(task, at: external)
        library.register(task, at: external)
        #expect(noted == [external])
        #expect(try Data(contentsOf: external) == original)
        var invalid = task
        invalid.title = " "
        #expect(throws: TaskValidationError.emptyTitle) { try library.save(invalid) }
        invalid = task
        let item = TaskMediaItem(title: "Duplicate", kind: .audio, source: .unassociated)
        invalid.items = [item, item]
        #expect(throws: TaskValidationError.duplicateMedia(item.id)) { try library.save(invalid) }
        #expect(noted == [external])
        #expect(library.task(for: task.id) == task)
        #expect(try Data(contentsOf: external) == original)
    }

    @Test func openingTaskDoesNotRewriteOriginalAndFailedSaveKeepsLastDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.voxline")
        let legacy = ProcessingTask()
        let original = try TaskDocumentCodec.encode(legacy)
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

    @Test func itemCommitPublishesOnlyAfterSavingAndRetainsRetryableDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = ProcessingTask(items: [.init(title: "Legacy", kind: .audio, source: .unassociated)])
        task.items[0].cues = [try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 500, sourceText: "Original")]
        let library = TaskLibrary(tasksDirectory: directory)
        try library.save(task)
        let url = try #require(library.url(for: task.id))
        let saved = try Data(contentsOf: url)
        let original = task.items[0]
        var draft = original
        try draft.editSubtitle(comparedTo: original.cues[0], sourceText: "Draft", translationText: "译文")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try library.updateItem(draft, taskID: task.id, comparedTo: original) }
        #expect(library.task(for: task.id) == task)
        #expect(draft.cues[0].sourceText == "Draft")
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
        try FileManager.default.removeItem(at: url)
        try saved.write(to: url)
        try library.updateItem(draft, taskID: task.id, comparedTo: original)
        #expect(library.task(for: task.id)?.items[0] == draft)
        #expect(try TaskDocumentCodec.decode(Data(contentsOf: url)).items[0] == draft)
        let committed = try Data(contentsOf: url)
        #expect(throws: TaskValidationError.taskChanged) {
            try library.updateItem(original, taskID: task.id, comparedTo: original)
        }
        #expect(try Data(contentsOf: url) == committed)
        #expect(library.task(for: task.id)?.items[0] == draft)
    }

    @Test func checkpointCommitUsesLatestPublishedEditsAndWriteFailureDoesNotPublishResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = TaskLibrary(tasksDirectory: directory)
        let media = try MediaIdentity(fileName: "sample.wav", byteCount: 42, fingerprint: String(repeating: "a", count: 64),
            durationMilliseconds: 5000, audioTrackID: 1)
        var task = ProcessingTask(items: [.init(title: "Sample", kind: .audio, source: .localFile(fileName: media.fileName), media: media)])
        try task.recordStart()
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
        let originalItem = edited.items[0]
        try edited.items[0].editSubtitle(comparedTo: originalItem.cues[0], sourceText: "Saved manual correction", translationText: "")
        try library.updateItem(edited.items[0], taskID: task.id, comparedTo: originalItem)
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
        #expect(reopened.items[0].cues[0].sourceText == "Saved manual correction")
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
