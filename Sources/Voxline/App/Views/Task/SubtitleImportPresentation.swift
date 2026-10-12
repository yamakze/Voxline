import SwiftUI
import VoxlineCore
import VoxlineWorkflow

@Observable @MainActor
final class SubtitleImportState {
    enum Presentation: String, Identifiable {
        case original, translation, unmatched
        var id: String { rawValue }
    }
    var presentation: Presentation?
    var confirmingSpeechRecognition = false
}

/// Shared actions; the platforms retain their own menus and layout.
struct SubtitleImportActions: View {
    @Bindable var state: SubtitleImportState
    let item: TaskMediaItem
    let isDisabled: Bool

    var body: some View {
        Section(String(localized: "字幕导入", bundle: appLocalizationBundle)) {
            Button {
                state.presentation = .original
            } label: {
                Label(item.cues.isEmpty ? String(localized: "导入原文字幕…", bundle: appLocalizationBundle)
                    : String(localized: "替换原文字幕…", bundle: appLocalizationBundle), systemImage: "doc.text")
            }
            .disabled(item.media == nil)

            Button {
                state.presentation = .translation
            } label: {
                Label(String(localized: "导入译文字幕…", bundle: appLocalizationBundle), systemImage: "character.book.closed")
            }
            .disabled(item.cues.isEmpty)

            if let unmatched = item.unmatchedTranslationEntries, !unmatched.isEmpty {
                Button {
                    state.presentation = .unmatched
                } label: {
                    Label(String(localized: "继续匹配未分配译文 (\(unmatched.count))…", bundle: appLocalizationBundle), systemImage: "arrow.triangle.merge")
                }
            }
            if item.importedSubtitleOrigin != nil {
                Button(role: .destructive) {
                    state.confirmingSpeechRecognition = true
                } label: {
                    Label(String(localized: "改用语音识别…", bundle: appLocalizationBundle), systemImage: "waveform")
                }
            }
        }
        .disabled(isDisabled)
    }
}

private struct SubtitleImportSheetsModifier: ViewModifier {
    @Bindable var state: SubtitleImportState
    let item: TaskMediaItem
    let taskID: UUID
    let library: TaskLibrary
    let session: ProofreadingSession
    let onCommit: (TaskMediaItem, TaskMediaItem) throws -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $state.presentation) { presentation in
                switch presentation {
                case .original:
                    SubtitleImportSheet(item: item) { selection, replacesExisting, snapshot in
                        let updated = try library.importOriginalSubtitles(selection, taskID: taskID,
                            comparedTo: snapshot, replacingExisting: replacesExisting)
                        session.recordSavedChange(updated, comparedTo: snapshot)
                    }
                case .translation:
                    SubtitleImportSheet(item: item, onCommit: saveTranslation)
                case .unmatched:
                    SubtitleImportSheet(resumingItem: item, onCommit: saveTranslation)
                }
            }
            .confirmationDialog(String(localized: "清除已有字幕并改用语音识别？", bundle: appLocalizationBundle),
                isPresented: $state.confirmingSpeechRecognition, titleVisibility: .visible) {
                Button(String(localized: "改用语音识别", bundle: appLocalizationBundle), role: .destructive) {
                    do {
                        let updated = try library.useSpeechRecognition(taskID: taskID, comparedTo: item)
                        session.recordSavedChange(updated, comparedTo: item)
                    } catch { session.errorMessage = error.localizedDescription }
                }
                Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
            } message: {
                Text(String(localized: "将清除当前媒体的原文和译文。", bundle: appLocalizationBundle))
            }
    }

    private func saveTranslation(_ assignments: [SubtitleTranslationAssignment], replacingExisting: Bool,
                                 comparedTo snapshot: TaskMediaItem) throws {
        var updated = snapshot
        try updated.importTranslations(assignments, comparedTo: snapshot.cues, replacingExisting: replacingExisting)
        try session.saveChanges(updated, comparedTo: snapshot, onCommit: onCommit)
    }
}

extension View {
    func subtitleImportSheets(state: SubtitleImportState, item: TaskMediaItem, taskID: UUID,
                              library: TaskLibrary, session: ProofreadingSession,
                              onCommit: @escaping (TaskMediaItem, TaskMediaItem) throws -> Void) -> some View {
        modifier(SubtitleImportSheetsModifier(state: state, item: item, taskID: taskID,
            library: library, session: session, onCommit: onCommit))
    }
}
