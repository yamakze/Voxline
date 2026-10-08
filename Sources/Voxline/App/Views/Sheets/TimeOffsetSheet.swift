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
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }.keyboardShortcut(.cancelAction)
            }

            Text(String(localized: "调整当前媒体中全部 \(cues.count) 条字幕的时间位置。正数向后延后，负数向前提前。", bundle: appLocalizationBundle))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(String(localized: "偏移时间（秒）：", bundle: appLocalizationBundle))
                    TextField("0.0", text: $offsetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Text(String(localized: "秒", bundle: appLocalizationBundle))
                    Spacer()
                    Button("-1.0s") { adjustOffset(by: -1.0) }
                    Button("-0.2s") { adjustOffset(by: -0.2) }
                    Button("+0.2s") { adjustOffset(by: 0.2) }
                    Button("+1.0s") { adjustOffset(by: 1.0) }
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
                        let newStart = Double(shifted.startMilliseconds) / 1000.0
                        Text(String(format: String(localized: "首条字幕将从 %.3f 秒调整为 %.3f 秒", bundle: appLocalizationBundle), locale: .current, Double(first.startMilliseconds) / 1000.0, newStart))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .liquidGlassSurface()

            HStack {
                Spacer()
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
