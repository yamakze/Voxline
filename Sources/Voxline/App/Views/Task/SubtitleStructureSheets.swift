import SwiftUI
import VoxlineCore

@Observable @MainActor
final class SubtitleStructureState {
    struct Insertion: Identifiable {
        let id = UUID()
        let startSeconds: Double
    }

    var insertion: Insertion?
    var timingCue: SubtitleCue?
    var splittingCue: SubtitleCue?
    var mergingCues: [SubtitleCue]?

    func insert(at seconds: Double) {
        insertion = Insertion(startSeconds: seconds)
    }
}

private struct IdentifiableCueList: Identifiable {
    var id: [UUID] { cues.map(\.id) }
    let cues: [SubtitleCue]
}

private struct SubtitleStructureSheetsModifier: ViewModifier {
    @Bindable var state: SubtitleStructureState
    let item: TaskMediaItem
    let session: ProofreadingSession
    let onCommit: (TaskMediaItem, TaskMediaItem) throws -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $state.insertion) { request in
                InsertSubtitleSheet(initialStartSeconds: request.startSeconds) { newCue in
                    var updated = item
                    try updated.insertSubtitle(newCue)
                    try session.saveChanges(updated, comparedTo: item, onCommit: onCommit)
                }
            }
            .sheet(item: $state.timingCue) { cue in
                AdjustTimingSheet(cue: cue) { startMs, endMs in
                    var updated = item
                    try updated.setSubtitleTiming(comparedTo: cue, startMilliseconds: startMs, endMilliseconds: endMs)
                    try session.saveChanges(updated, comparedTo: item, onCommit: onCommit)
                }
            }
            .sheet(item: $state.splittingCue) { cue in
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
            }
            .sheet(item: Binding(
                get: { state.mergingCues.map { IdentifiableCueList(cues: $0) } },
                set: { state.mergingCues = $0?.cues }
            )) { payload in
                MergeSubtitlesSheet(cues: payload.cues) { mergedSource, mergedTrans in
                    var updated = item
                    try updated.mergeSubtitles(
                        comparedTo: payload.cues,
                        sourceText: mergedSource,
                        translationText: mergedTrans
                    )
                    try session.saveChanges(updated, comparedTo: item, onCommit: onCommit)
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
