#if os(macOS)
import SwiftUI
import VoxlineCore

public struct TimeOffsetSheet: View {
    let cues: [SubtitleCue]
    let mediaDurationMilliseconds: Int64?
    let onCommit: ([SubtitleCue], [SubtitleCue]) throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var offsetText = "0.000"
    @State private var validationError: String?
    @State private var saveError: String?
    @State private var shiftedCues: [SubtitleCue] = []

    public init(cues: [SubtitleCue], mediaDurationMilliseconds: Int64? = nil,
                onCommit: @escaping ([SubtitleCue], [SubtitleCue]) throws -> Void) {
        self.cues = cues
        self.mediaDurationMilliseconds = mediaDurationMilliseconds
        self.onCommit = onCommit
    }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(String(localized: "整体时间偏移", bundle: appLocalizationBundle)).font(.headline)
                Spacer()
            }

            Text(String(format: String(localized: "共 %lld 条字幕", bundle: appLocalizationBundle), locale: .current, Int64(cues.count)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(String(localized: "偏移量：", bundle: appLocalizationBundle))
                        .font(.body)

                    TextField("0.000", text: $offsetText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .frame(width: 90)

                    Text(String(localized: "秒", bundle: appLocalizationBundle))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    HStack(spacing: 6) {
                        Button("-1.0s") { adjustOffset(by: -1.0) }
                        Button("-0.2s") { adjustOffset(by: -0.2) }
                        Button("+0.2s") { adjustOffset(by: 0.2) }
                        Button("+1.0s") { adjustOffset(by: 1.0) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let saveError {
                    Text(saveError).font(.callout).foregroundStyle(.red)
                }

                if let validationError {
                    Text(validationError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if shiftedCues != cues {
                    if let first = cues.first, let shifted = shiftedCues.first {
                        let origStr = TimecodeFormatter.formatTimestamp(milliseconds: first.startMilliseconds)
                        let newStr = TimecodeFormatter.formatTimestamp(milliseconds: shifted.startMilliseconds)
                        Text(String(format: String(localized: "首条字幕将从 %@ 调整为 %@", bundle: appLocalizationBundle), locale: .current, origStr, newStr))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .liquidGlassSurface()

            HStack(spacing: 12) {
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "应用偏移", bundle: appLocalizationBundle)) {
                    applyOffset()
                }
                .buttonStyle(.borderedProminent)
                .disabled(shiftedCues == cues || validationError != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onChange(of: offsetText) { _, _ in validateOffset() }
        .onChange(of: cues) { _, _ in validateOffset() }
        .onAppear { validateOffset() }
    }

    private func adjustOffset(by delta: Double) {
        guard let seconds = Double(offsetText.trimmingCharacters(in: .whitespacesAndNewlines)), seconds.isFinite else {
            validationError = SubtitleTimeOffsetError.invalidOffset.localizedDescription
            return
        }
        offsetText = String(format: "%.3f", seconds + delta)
    }

    private func validateOffset() {
        do {
            guard let seconds = Double(offsetText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SubtitleTimeOffsetError.invalidOffset
            }
            let milliseconds = try SubtitleTimeOffset.milliseconds(from: seconds)
            shiftedCues = try SubtitleTimeOffset.shifted(cues, by: milliseconds, withinDuration: mediaDurationMilliseconds)
            validationError = nil
        } catch {
            shiftedCues = []
            validationError = error.localizedDescription
        }
    }

    private func applyOffset() {
        validateOffset()
        guard validationError == nil else { return }
        do {
            try onCommit(shiftedCues, cues)
            dismiss()
        } catch { saveError = error.localizedDescription }
    }
}

#endif
