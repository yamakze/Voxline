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
        let session = ProofreadingSession(previewKind: .source)
        session.updateSubtitles(item.cues)
        #expect(session.hasUntranslatedCues)
        session.searchQuery = "人工译文"
        #expect(session.transcriptRows.isEmpty)
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
        #expect(session.transcriptRows.first?.cue == saved.cues.first)
        #expect(session.transcriptRows.first?.nextCue == nil)
        #expect(!session.hasUntranslatedCues)
        session.updateSubtitles(saved.cues) // The page receives the same successful save via observation.
        session.searchQuery = "Corrected"
        #expect(session.transcriptRows.first?.cue == saved.cues.first)
        session.beginEditing(try #require(saved.cues.first))
        session.sourceDraft = "Unsaved draft"
        #expect(!session.canUndo(in: saved))
        #expect(throws: CheckpointError.editedCue) {
            try session.undo(in: saved) { _, _ in Issue.record("Subtitle undo interrupted text editing") }
        }
        #expect(session.sourceDraft == "Unsaved draft")
        #expect(TaskLibrary(tasksDirectory: root).task(for: task.id)?.items.first == saved)
        session.cancelEditing()
        #expect(session.canUndo(in: saved))
        try session.undo(in: saved) { edited, original in
            try library.updateItem(edited, taskID: task.id, comparedTo: original)
        }
        #expect(session.hasUntranslatedCues)
        #expect(TaskLibrary(tasksDirectory: root).task(for: task.id)?.items.first == item)
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
        session.searchQuery = "Line 0"
        #expect(session.transcriptRows.count == 1)
        #expect(session.transcriptRows.first?.nextCue == cues[1])
        var deleted = original
        try deleted.deleteSubtitles(comparedTo: [cues[0]])
        try session.saveChanges(deleted, comparedTo: original) { edited, before in
            try library.updateItem(edited, taskID: task.id, comparedTo: before)
        }
        var newer = deleted
        try newer.editSubtitle(comparedTo: cues[1], sourceText: "New manual edit", translationText: "")
        try library.updateItem(newer, taskID: task.id, comparedTo: deleted)
        #expect(!session.canUndo(in: newer))
        #expect(session.transcriptRows.isEmpty)
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

    @Test func sourceReplacementAndRecognitionResetUndoRestoreCheckpointTranslationsAndOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try MediaIdentity(fileName: "clip.mp4", byteCount: 123,
            fingerprint: String(repeating: "a", count: 64), durationMilliseconds: 1000, audioTrackID: 1)
        let item = TaskMediaItem(title: "clip", kind: .video, source: .localFile(fileName: media.fileName), media: media)
        let task = ProcessingTask(items: [item])
        let library = TaskLibrary(tasksDirectory: root)
        try library.save(task)
        let imported = try library.importOriginalSubtitles(.init(entries: [
            .init(startMilliseconds: 0, endMilliseconds: 800, text: "Original")
        ], origin: .file(name: "source.srt")), taskID: task.id, comparedTo: item)
        let session = ProofreadingSession(item: imported)
        session.beginEditing(imported.cues[0])
        session.sourceDraft = "Manual source"
        session.translationDraft = "人工译文"
        try session.saveEditing(in: imported) { updated, original in
            try library.updateItem(updated, taskID: task.id, comparedTo: original)
        }
        let edited = try #require(library.task(for: task.id)?.items.first)
        let reset = try library.useSpeechRecognition(taskID: task.id, comparedTo: edited)
        session.recordSavedChange(reset, comparedTo: edited)
        #expect(reset.checkpoint == nil && reset.cues.isEmpty && reset.importedSubtitleOrigin == nil)
        try session.undo(in: reset) { updated, original in
            try library.updateItem(updated, taskID: task.id, comparedTo: original)
        }
        #expect(TaskLibrary(tasksDirectory: root).task(for: task.id)?.items.first == edited)
        let replacement = try library.importOriginalSubtitles(.init(entries: [
            .init(startMilliseconds: 100, endMilliseconds: 500, text: "Replacement")
        ], origin: .file(name: "replacement.vtt")), taskID: task.id, comparedTo: edited, replacingExisting: true)
        session.recordSavedChange(replacement, comparedTo: edited)
        // A task updated after the preview was opened cannot be replaced by a stale import.
        #expect(throws: CheckpointError.editedCue) {
            try library.useSpeechRecognition(taskID: task.id, comparedTo: edited)
        }
        try session.undo(in: replacement) { updated, original in
            try library.updateItem(updated, taskID: task.id, comparedTo: original)
        }
        #expect(TaskLibrary(tasksDirectory: root).task(for: task.id)?.items.first == edited)
    }

}
