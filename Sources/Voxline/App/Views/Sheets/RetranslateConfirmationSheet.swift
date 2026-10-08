import SwiftUI
import VoxlineCore

public struct RetranslateConfirmationSheet: View {
    let affectedCues: [SubtitleCue]
    let onConfirm: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(affectedCues: [SubtitleCue], onConfirm: @escaping (Bool) -> Void) {
        self.affectedCues = affectedCues
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(String(localized: "重译覆盖选择", bundle: appLocalizationBundle)).font(.headline)
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }.keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label(String(localized: "本次选择 \(affectedCues.count) 条字幕。", bundle: appLocalizationBundle), systemImage: "character.bubble")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text(String(localized: "仅翻译无译文的字幕将保留全部已有译文，包括手工校对和待重译内容。覆盖重译会替换所选字幕的已有译文，使用本次任务冻结的服务与模型。", bundle: appLocalizationBundle))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(affectedCues.prefix(10)) { cue in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cue.sourceText).font(.callout.bold())
                                if case .succeeded(let text, _) = cue.translation {
                                    Text(String(localized: "当前译文：\(text)", bundle: appLocalizationBundle)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                        if affectedCues.count > 10 {
                            Text(String(localized: "… 以及其余 \(affectedCues.count - 10) 条", bundle: appLocalizationBundle)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 180)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 8))
            }
            .padding()
            .liquidGlassSurface()

            HStack(spacing: 12) {
                Spacer()
                Button(String(localized: "仅翻译无译文字幕", bundle: appLocalizationBundle)) {
                    onConfirm(false)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(!affectedCues.contains { cue in
                    if case .succeeded = cue.translation { return false }
                    return true
                })

                Button(String(localized: "覆盖所选字幕并重译", bundle: appLocalizationBundle)) {
                    onConfirm(true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 520)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}

