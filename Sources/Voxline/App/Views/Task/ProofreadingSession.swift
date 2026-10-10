import Foundation
import Observation
import VoxlineCore

/// Shared editing state; platform views supply their current item and atomic commit operation.
@Observable @MainActor
final class ProofreadingSession {
    struct TranscriptRow: Identifiable {
        var id: UUID { cue.id }
        let cue: SubtitleCue
        let nextCue: SubtitleCue?
    }

    var previewKind: SRTOutputKind
    var searchQuery = "" {
        didSet { filterTranscriptRows() }
    }
    private(set) var transcriptRows: [TranscriptRow] = []
    private(set) var hasUntranslatedCues = false
    @ObservationIgnored private var allTranscriptRows: [TranscriptRow] = []
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
        updateSubtitles(item?.cues ?? [])
    }

    func updateSubtitles(_ cues: [SubtitleCue]) {
        guard allTranscriptRows.count != cues.count ||
              !zip(allTranscriptRows, cues).allSatisfy({ $0.cue == $1 }) else { return }
        allTranscriptRows = cues.indices.map { index in
            TranscriptRow(cue: cues[index], nextCue: index + 1 < cues.count ? cues[index + 1] : nil)
        }
        hasUntranslatedCues = cues.contains { !$0.hasTranslation }
        filterTranscriptRows()
    }

    private func filterTranscriptRows() {
        transcriptRows = searchQuery.isEmpty ? allTranscriptRows : allTranscriptRows.filter { row in
            if row.cue.sourceText.localizedCaseInsensitiveContains(searchQuery) { return true }
            if case .succeeded(let text, _) = row.cue.translation { return text.localizedCaseInsensitiveContains(searchQuery) }
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
            updateSubtitles(updated.cues)
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
        updateSubtitles(updated.cues)
        lastEdit = nil
        selectedCueIDs.formIntersection(updated.cues.map(\.id))
        errorMessage = nil
    }
}
