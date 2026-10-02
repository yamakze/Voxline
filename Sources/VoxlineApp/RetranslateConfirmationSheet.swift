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
                Text("重译覆盖选择").font(.headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("检测到 \(affectedCues.count) 条已修改原文或包含手工校对的字幕。", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text("重新翻译时，您可以选择保留已有手工翻译结果，或使用新生成的译文进行覆盖。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(affectedCues.prefix(10)) { cue in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cue.sourceText).font(.callout.bold())
                                if case .succeeded(let text, _) = cue.translation {
                                    Text("当前译文：\(text)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                        if affectedCues.count > 10 {
                            Text("… 以及其余 \(affectedCues.count - 10) 条").font(.caption).foregroundStyle(.secondary)
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
                Button("仅重译未完成项（保留手工）") {
                    onConfirm(false)
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("全部覆盖重译") {
                    onConfirm(true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
