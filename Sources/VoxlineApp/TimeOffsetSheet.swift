import SwiftUI
import VoxlineCore

public struct TimeOffsetSheet: View {
    @Binding var cues: [SubtitleCue]
    let mediaDurationMilliseconds: Int64?
    @Environment(\.dismiss) private var dismiss

    @State private var offsetSeconds: Double = 0.0
    @State private var offsetMilliseconds: Int64 = 0
    @State private var validationError: String?

    public init(cues: Binding<[SubtitleCue]>, mediaDurationMilliseconds: Int64? = nil) {
        _cues = cues
        self.mediaDurationMilliseconds = mediaDurationMilliseconds
    }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("整体时间偏移").font(.headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            Text("调整当前媒体中全部 \(cues.count) 条字幕的时间位置。正数向后延后，负数向前提前。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("偏移时间（秒）：")
                    TextField("0.0", value: $offsetSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Text("秒")
                    Spacer()
                    Button("-1.0s") { adjustOffset(by: -1.0) }
                    Button("-0.2s") { adjustOffset(by: -0.2) }
                    Button("+0.2s") { adjustOffset(by: 0.2) }
                    Button("+1.0s") { adjustOffset(by: 1.0) }
                }

                if let validationError {
                    Text(validationError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if offsetMilliseconds != 0 {
                    let first = cues.first
                    if let first {
                        let newStart = Double(first.startMilliseconds + offsetMilliseconds) / 1000.0
                        Text(String(format: "首条字幕将从 %.3f 秒调整为 %.3f 秒", Double(first.startMilliseconds) / 1000.0, newStart))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .liquidGlassSurface()

            HStack {
                Spacer()
                Button("应用偏移") {
                    applyOffset()
                }
                .buttonStyle(.borderedProminent)
                .disabled(offsetMilliseconds == 0 || validationError != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onChange(of: offsetSeconds) { _, newValue in
            offsetMilliseconds = Int64((newValue * 1000).rounded())
            validateOffset()
        }
    }

    private func adjustOffset(by delta: Double) {
        offsetSeconds = (offsetSeconds + delta)
        offsetMilliseconds = Int64((offsetSeconds * 1000).rounded())
        validateOffset()
    }

    private func validateOffset() {
        validationError = nil
        if offsetMilliseconds == 0 { return }

        for cue in cues {
            let newStart = cue.startMilliseconds + offsetMilliseconds
            let newEnd = cue.endMilliseconds + offsetMilliseconds
            if newStart < 0 {
                validationError = "非法时间：首条或部分字幕偏移后开始时间小于 0 秒（产生负时间）。"
                return
            }
            if newEnd <= newStart {
                validationError = "非法时间：字幕结束时间小于或等于开始时间（产生时间倒置）。"
                return
            }
            if let duration = mediaDurationMilliseconds, newEnd > duration {
                validationError = String(format: "非法时间：部分字幕偏移后超出媒体总时长（%.1f 秒）。", Double(duration) / 1000.0)
                return
            }
        }
    }

    private func applyOffset() {
        validateOffset()
        guard validationError == nil else { return }

        for index in cues.indices {
            cues[index].startMilliseconds += offsetMilliseconds
            cues[index].endMilliseconds += offsetMilliseconds
        }
        dismiss()
    }
}
