import Foundation
import Testing
import VoxlineCore
import VoxlineWorkflow
@testable import VoxlineApp

@Suite("Proofreading commits", .serialized) @MainActor
struct ProofreadingSessionTests {
    @Test func failedSaveRetainsDraftAndRetryUsesTheSameEditingSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cue = try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 1000, sourceText: "Before")
        let item = TaskMediaItem(title: "Media", kind: .audio, source: .unassociated, cues: [cue])
        let task = ProcessingTask(title: "Proofreading", items: [item])
        let library = TaskLibrary(tasksDirectory: root)
        try library.save(task)
        let session = ProofreadingSession(item: item)
        session.beginEditing(cue)
        session.sourceDraft = "Corrected"
        session.translationDraft = "人工译文"
        let file = library.defaultURL(for: task.id)
        let backup = root.appendingPathComponent("task.backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try session.saveEditing(in: item) { edited, original in
                try library.updateItem(edited, taskID: task.id, comparedTo: original)
            }
        }
        #expect(library.task(for: task.id) == task)
        #expect(session.editingSnapshot == cue)
        #expect(session.sourceDraft == "Corrected" && session.translationDraft == "人工译文")
        #expect(!session.canUndo(in: item))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        try session.saveEditing(in: item) { edited, original in
            try library.updateItem(edited, taskID: task.id, comparedTo: original)
        }
        let saved = try #require(TaskLibrary(tasksDirectory: root).task(for: task.id)?.items.first)
        #expect(saved.cues.first?.sourceText == "Corrected")
        #expect(saved.cues.first?.hasTranslation == true)
        #expect(session.editingSnapshot == nil)
        #expect(session.canUndo(in: saved))
    }

    @Test func undoPersistsThePreviousTimelineAndRejectsInterveningEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cues = try (0..<2).map { try SubtitleCue(id: UUID(), startMilliseconds: Int64($0 * 1000),
            endMilliseconds: Int64($0 * 1000 + 500), sourceText: "Line \($0)") }
        let original = TaskMediaItem(title: "Media", kind: .audio, source: .unassociated, cues: cues)
        let task = ProcessingTask(title: "Proofreading", items: [original])
        let library = TaskLibrary(tasksDirectory: root)
        try library.save(task)
        let session = ProofreadingSession(item: original)
        var deleted = original
        try deleted.deleteSubtitles(comparedTo: [cues[0]])
        try session.saveChanges(deleted, comparedTo: original) { edited, before in
            try library.updateItem(edited, taskID: task.id, comparedTo: before)
        }
        var newer = deleted
        try newer.editSubtitle(comparedTo: cues[1], sourceText: "New manual edit", translationText: "")
        try library.updateItem(newer, taskID: task.id, comparedTo: deleted)
        #expect(!session.canUndo(in: newer))
        #expect(throws: CheckpointError.editedCue) { try session.undo(in: newer) { _, _ in Issue.record("Stale undo reached persistence") } }
        #expect(library.task(for: task.id)?.items[0] == newer)
        // A separately saved operation can be undone against its exact accepted timeline.
        var merged = newer
        try merged.insertSubtitle(cues[0])
        try session.saveChanges(merged, comparedTo: newer) { edited, before in
            try library.updateItem(edited, taskID: task.id, comparedTo: before)
        }
        try session.undo(in: merged) { edited, before in
            try library.updateItem(edited, taskID: task.id, comparedTo: before)
        }
        #expect(TaskLibrary(tasksDirectory: root).task(for: task.id)?.items[0] == newer)
        #expect(!session.canUndo(in: newer))
    }

    @Test func deletingTheLastSubtitleCanBeSavedAndUndone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var cue = try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 1000, sourceText: "Manual source")
        cue.translation = .succeeded(text: "人工译文", sourceRevision: cue.sourceRevision)
        let original = TaskMediaItem(title: "Media", kind: .audio, source: .unassociated, cues: [cue])
        let task = ProcessingTask(title: "Last subtitle", items: [original])
        let library = TaskLibrary(tasksDirectory: root)
        try library.save(task)
        let session = ProofreadingSession(item: original)
        var deleted = original
        try deleted.deleteSubtitles(comparedTo: [cue])
        try session.saveChanges(deleted, comparedTo: original) { edited, before in
            try library.updateItem(edited, taskID: task.id, comparedTo: before)
        }
        #expect(TaskLibrary(tasksDirectory: root).task(for: task.id)?.items.first?.cues.isEmpty == true)
        #expect(session.canUndo(in: deleted))
        try session.undo(in: deleted) { edited, before in
            try library.updateItem(edited, taskID: task.id, comparedTo: before)
        }
        #expect(TaskLibrary(tasksDirectory: root).task(for: task.id)?.items.first == original)
    }

}
