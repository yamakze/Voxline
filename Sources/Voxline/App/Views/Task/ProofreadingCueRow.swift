import SwiftUI
import VoxlineCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ProofreadingCueRow: View {
    let cue: SubtitleCue
    let nextCue: SubtitleCue?
    @Bindable var session: ProofreadingSession
    let isActive: Bool
    @State private var isHovered = false
    var isPast = false
    let canRetranslate: Bool
    let isTaskRunning: Bool

    let onSeek: (Int64) -> Void
    let onRetranslate: (SubtitleCue) -> Void
    var onSaveEdit: (() -> Void)? = nil
    let onAdjustTiming: (SubtitleCue) -> Void
    let onSplit: (SubtitleCue) -> Void
    let onMerge: ([SubtitleCue]) -> Void
    let onDelete: (SubtitleCue) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isEditing: Bool {
        onSaveEdit != nil && session.editingSnapshot?.id == cue.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if session.isSelecting {
                Button {
                    if session.selectedCueIDs.contains(cue.id) {
                        session.selectedCueIDs.remove(cue.id)
                    } else {
                        session.selectedCueIDs.insert(cue.id)
                    }
                } label: {
                    Image(systemName: session.selectedCueIDs.contains(cue.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(session.selectedCueIDs.contains(cue.id) ? Color.voxlineAccent : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.selectedCueIDs.contains(cue.id)
                    ? String(localized: "取消选择", bundle: appLocalizationBundle)
                    : String(localized: "选择", bundle: appLocalizationBundle))
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                topBar
                textContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.voxlineActiveCueBackground)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isActive ? Color.voxlineActiveCueBorder : Color.clear, lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(Color.voxlineAccent)
                    .frame(width: 3.5)
                    .padding(.vertical, 6)
                    .padding(.leading, 3)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .opacity(isActive ? 1.0 : (isHovered ? 0.95 : (isPast ? 0.40 : 0.70)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isActive)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .contextMenu {
            actionMenuItems
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                onSeek(cue.startMilliseconds)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isActive ? "speaker.wave.2.fill" : "play.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text(formatCueTimestamp(cue.startMilliseconds))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                    in: .capsule
                )
                .overlay(
                    Capsule().strokeBorder(isActive ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 0.8)
                )
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            if isEditing {
                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                    session.cancelEditing()
                }
                .buttonStyle(.plain)
                .font(.caption)
                if let onSaveEdit {
                    Button {
                        onSaveEdit()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(String(localized: "保存", bundle: appLocalizationBundle))
                    .help(String(localized: "保存", bundle: appLocalizationBundle))
                }
            } else if !session.isSelecting {
                Menu {
                    actionMenuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "更多操作", bundle: appLocalizationBundle))
            }
        }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                TextField(String(localized: "原文内容", bundle: appLocalizationBundle), text: $session.sourceDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.voxlineTextBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.voxlineAccent.opacity(0.5), lineWidth: 1)
                    )

                TextField(String(localized: "译文内容", bundle: appLocalizationBundle), text: $session.translationDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.voxlineTextBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.voxlineTranslationText.opacity(0.4), lineWidth: 1)
                    )
            } else {
                if session.previewKind != .translation {
                    Text(cue.sourceText)
                        .font(.system(size: isActive ? 18 : 16, weight: isActive ? .bold : .medium))
                        .lineSpacing(3)
                        .contentShape(Rectangle())
                        .onTapGesture { onSeek(cue.startMilliseconds) }
                }

                if session.previewKind != .source {
                    switch cue.translation {
                    case .succeeded(let trans, _):
                        Text(trans)
                            .font(.system(size: isActive ? 16 : 14, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(session.previewKind == .bilingual ? Color.voxlineTranslationText : .primary)
                            .lineSpacing(2)
                            .contentShape(Rectangle())
                            .onTapGesture { onSeek(cue.startMilliseconds) }
                    case .failed(let reason):
                        Text(String(localized: "翻译失败：\(reason)", bundle: appLocalizationBundle))
                            .font(.caption)
                            .foregroundStyle(.red)
                    case .pending:
                        Text(String(localized: "待翻译", bundle: appLocalizationBundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionMenuItems: some View {
        Button {
            session.beginEditing(cue)
        } label: {
            Label(String(localized: "编辑", bundle: appLocalizationBundle), systemImage: "pencil")
        }
        .disabled(session.editingSnapshot?.id != nil)

        Button {
            onAdjustTiming(cue)
        } label: {
            Label(String(localized: "调整时间…", bundle: appLocalizationBundle), systemImage: "timer")
        }
        .disabled(isTaskRunning || session.editingSnapshot?.id != nil)

        Button {
            onSplit(cue)
        } label: {
            Label(String(localized: "拆分字幕…", bundle: appLocalizationBundle), systemImage: "scissors")
        }
        .disabled(isTaskRunning || session.editingSnapshot?.id != nil)

        if let nextCue {
            Button {
                onMerge([cue, nextCue])
            } label: {
                Label(String(localized: "与下一句合并…", bundle: appLocalizationBundle), systemImage: "arrow.triangle.merge")
            }
            .disabled(isTaskRunning || session.editingSnapshot?.id != nil)
        }

        if canRetranslate {
            Divider()
            Button {
                onRetranslate(cue)
            } label: {
                Label(String(localized: "重新翻译", bundle: appLocalizationBundle), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(session.editingSnapshot?.id != nil || isTaskRunning)
        }

        Divider()

        Button {
            copyCueTextToPasteboard(cue.sourceText)
        } label: {
            Label(String(localized: "复制原文", bundle: appLocalizationBundle), systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            onDelete(cue)
        } label: {
            Label(String(localized: "删除", bundle: appLocalizationBundle), systemImage: "trash")
        }
        .disabled(isTaskRunning || session.editingSnapshot?.id != nil)
    }

    private func copyCueTextToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    private func formatCueTimestamp(_ milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1000
        let ms = milliseconds % 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02lld:%02lld.%03lld", minutes, seconds, ms)
    }
}
