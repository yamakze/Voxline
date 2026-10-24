import SwiftUI
import VoxlineCore

@Observable @MainActor
final class SubtitleStructureState {
    enum Presentation: Identifiable {
        case insertion(startSeconds: Double)
        case timing(SubtitleCue)
        case splitting(SubtitleCue)
        case merging([SubtitleCue])

        var id: Int {
            switch self {
            case .insertion: 0
            case .timing: 1
            case .splitting: 2
            case .merging: 3
            }
        }
    }

    var presentation: Presentation?

    func insert(at seconds: Double) { presentation = .insertion(startSeconds: seconds) }
}

private struct SubtitleStructureSheetsModifier: ViewModifier {
    @Bindable var state: SubtitleStructureState
    let item: TaskMediaItem
    let session: ProofreadingSession
    let onCommit: (TaskMediaItem, TaskMediaItem) throws -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $state.presentation) { presentation in
                switch presentation {
                case .insertion(let startSeconds):
                    InsertSubtitleSheet(initialStartSeconds: startSeconds) { newCue in
                        var updated = item
                        try updated.insertSubtitle(newCue)
                        try session.saveChanges(updated, comparedTo: item, onCommit: onCommit)
                    }
                case .timing(let cue):
                    AdjustTimingSheet(cue: cue) { startMs, endMs in
                        var updated = item
                        try updated.setSubtitleTiming(comparedTo: cue, startMilliseconds: startMs, endMilliseconds: endMs)
                        try session.saveChanges(updated, comparedTo: item, onCommit: onCommit)
                    }
                case .splitting(let cue):
                    SplitSubtitleSheet(cue: cue) { atMs, s1, s2, t1, t2 in
                        var updated = item
                        try updated.splitSubtitle(
                            comparedTo: cue,
                            atMilliseconds: atMs,
                            firstSourceText: s1,
                            secondSourceText: s2,
                            firstTranslationText: t1,
                            secondTranslationText: t2
                        )
                        try session.saveChanges(updated, comparedTo: item, onCommit: onCommit)
                    }
                case .merging(let cues):
                    MergeSubtitlesSheet(cues: cues) { mergedSource, mergedTrans in
                        var updated = item
                        try updated.mergeSubtitles(
                            comparedTo: cues,
                            sourceText: mergedSource,
                            translationText: mergedTrans
                        )
                        try session.saveChanges(updated, comparedTo: item, onCommit: onCommit)
                    }
                }
            }
    }
}

extension View {
    func subtitleStructureSheets(
        state: SubtitleStructureState,
        item: TaskMediaItem,
        session: ProofreadingSession,
        onCommit: @escaping (TaskMediaItem, TaskMediaItem) throws -> Void
    ) -> some View {
        modifier(SubtitleStructureSheetsModifier(state: state, item: item, session: session, onCommit: onCommit))
    }
}
