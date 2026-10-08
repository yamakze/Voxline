import Foundation
import Observation
import VoxlineCore

/// Shared editing state; platform views supply their current item and atomic commit operation.
@Observable @MainActor
final class ProofreadingSession {
    var previewKind: SRTOutputKind
    var searchQuery = ""
    var errorMessage: String?
    var editingSnapshot: SubtitleCue?
    var sourceDraft = ""
    var translationDraft = ""
    var isSelecting = false
    var selectedCueIDs = Set<UUID>()
    var retranslatingCues: [SubtitleCue]?
    private var lastEdit: (mediaID: UUID, before: [SubtitleCue], after: [SubtitleCue])?

    init(item: TaskMediaItem?) {
        previewKind = item?.cues.contains(where: \.hasTranslation) == true ? .bilingual : .source
    }

    func filteredCues(in item: TaskMediaItem) -> [SubtitleCue] {
        guard !searchQuery.isEmpty else { return item.cues }
        return item.cues.filter { cue in
            if cue.sourceText.localizedCaseInsensitiveContains(searchQuery) { return true }
            if case .succeeded(let text, _) = cue.translation { return text.localizedCaseInsensitiveContains(searchQuery) }
            return false
        }
    }

    func beginEditing(_ cue: SubtitleCue) {
        editingSnapshot = cue
        sourceDraft = cue.sourceText
        if case .succeeded(let text, _) = cue.translation { translationDraft = text }
        else { translationDraft = "" }
    }

    func cancelEditing() { editingSnapshot = nil }

    func saveEditing(in item: TaskMediaItem, onCommit: (TaskMediaItem, TaskMediaItem) throws -> Void) throws {
        guard let snapshot = editingSnapshot else { throw CheckpointError.editedCue }
        var updated = item
        try updated.editSubtitle(comparedTo: snapshot, sourceText: sourceDraft, translationText: translationDraft)
        try saveChanges(updated, comparedTo: item, onCommit: onCommit)
        editingSnapshot = nil
    }

    func saveChanges(_ updated: TaskMediaItem, comparedTo original: TaskMediaItem,
                     onCommit: (TaskMediaItem, TaskMediaItem) throws -> Void) throws {
        try onCommit(updated, original)
        if updated.cues != original.cues {
            lastEdit = (original.id, original.cues, updated.cues)
        }
        selectedCueIDs.formIntersection(updated.cues.map(\.id))
        errorMessage = nil
    }

    func canUndo(in item: TaskMediaItem) -> Bool {
        lastEdit?.mediaID == item.id && lastEdit?.after == item.cues
    }

    func undo(in item: TaskMediaItem, onCommit: (TaskMediaItem, TaskMediaItem) throws -> Void) throws {
        guard let edit = lastEdit, edit.mediaID == item.id else { throw CheckpointError.editedCue }
        var updated = item
        try updated.replaceSubtitles(edit.before, comparedTo: edit.after)
        try onCommit(updated, item)
        lastEdit = nil
        selectedCueIDs.formIntersection(updated.cues.map(\.id))
        errorMessage = nil
    }
}
