import SwiftUI
import VoxlineCore

// MARK: - 1. 添加单句字幕
struct InsertSubtitleSheet: View {
    let onSave: (SubtitleCue) throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var startText: String
    @State private var endText: String
    @State private var sourceText: String = ""
    @State private var translationText: String = ""
    @State private var errorMessage: String?

    init(initialStartSeconds: Double, onSave: @escaping (SubtitleCue) throws -> Void) {
        self.onSave = onSave

        let start = max(0, initialStartSeconds)
        let end = start + 3.0
        _startText = State(initialValue: String(format: "%.3f", start))
        _endText = State(initialValue: String(format: "%.3f", end))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.voxlineAccent.opacity(0.12))
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.voxlineAccent)
                }
                .frame(width: 24, height: 24)
                Text(String(localized: "添加字幕", bundle: appLocalizationBundle))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if os(macOS)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
            #else
            .background(.regularMaterial)
            #endif

            Form {
                Section(String(localized: "时间轴", bundle: appLocalizationBundle)) {
                    LabeledContent(String(localized: "开始时间", bundle: appLocalizationBundle)) {
                        HStack(spacing: 4) {
                            TextField("", text: $startText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 90)
                            Text(String(localized: "秒", bundle: appLocalizationBundle))
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(String(localized: "结束时间", bundle: appLocalizationBundle)) {
                        HStack(spacing: 4) {
                            TextField("", text: $endText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 90)
                            Text(String(localized: "秒", bundle: appLocalizationBundle))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(String(localized: "字幕内容", bundle: appLocalizationBundle)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "原文内容", bundle: appLocalizationBundle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $sourceText)
                            .font(.body)
                            .frame(minHeight: 56, maxHeight: 110)
                            .padding(4)
                            .background(Color.voxlineTextBackground, in: .rect(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "译文内容（选填）", bundle: appLocalizationBundle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $translationText)
                            .font(.body)
                            .frame(minHeight: 56, maxHeight: 110)
                            .padding(4)
                            .background(Color.voxlineTextBackground, in: .rect(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "保存", bundle: appLocalizationBundle)) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if os(macOS)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
            #else
            .background(.regularMaterial)
            #endif
        }
        #if os(macOS)
        .frame(width: 480, height: 460)
        #endif
    }

    private func save() {
        guard let startSec = Double(startText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let endSec = Double(endText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = String(localized: "请输入有效的起止时间。", bundle: appLocalizationBundle)
            return
        }
        guard startSec >= 0 else {
            errorMessage = String(localized: "开始时间必须大于或等于 0 秒。", bundle: appLocalizationBundle)
            return
        }
        guard endSec > startSec else {
            errorMessage = String(localized: "结束时间必须大于开始时间。", bundle: appLocalizationBundle)
            return
        }
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            errorMessage = String(localized: "原文内容不能为空。", bundle: appLocalizationBundle)
            return
        }

        do {
            let startMs = try SubtitleTimeOffset.milliseconds(from: startSec)
            let endMs = try SubtitleTimeOffset.milliseconds(from: endSec)
            var cue = try SubtitleCue(id: UUID(), startMilliseconds: startMs, endMilliseconds: endMs, sourceText: trimmedSource)
            let trimmedTrans = translationText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTrans.isEmpty {
                cue.translation = .succeeded(text: trimmedTrans, sourceRevision: cue.sourceRevision)
            }
            try onSave(cue)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 2. 逐条校时表单
struct AdjustTimingSheet: View {
    let cue: SubtitleCue
    let onSave: (Int64, Int64) throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var startText: String
    @State private var endText: String
    @State private var errorMessage: String?

    init(cue: SubtitleCue, onSave: @escaping (Int64, Int64) throws -> Void) {
        self.cue = cue
        self.onSave = onSave
        _startText = State(initialValue: String(format: "%.3f", Double(cue.startMilliseconds) / 1000.0))
        _endText = State(initialValue: String(format: "%.3f", Double(cue.endMilliseconds) / 1000.0))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.voxlineAccent.opacity(0.12))
                    Image(systemName: "clock")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.voxlineAccent)
                }
                .frame(width: 24, height: 24)
                Text(String(localized: "调整时间", bundle: appLocalizationBundle))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if os(macOS)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
            #else
            .background(.regularMaterial)
            #endif

            Form {
                Section(String(localized: "当前字幕", bundle: appLocalizationBundle)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cue.sourceText)
                            .font(.body)
                        if case .succeeded(let trans, _) = cue.translation {
                            Text(trans)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section(String(localized: "时间轴", bundle: appLocalizationBundle)) {
                    LabeledContent(String(localized: "开始时间", bundle: appLocalizationBundle)) {
                        HStack(spacing: 4) {
                            TextField("", text: $startText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 90)
                            Text(String(localized: "秒", bundle: appLocalizationBundle))
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(String(localized: "结束时间", bundle: appLocalizationBundle)) {
                        HStack(spacing: 4) {
                            TextField("", text: $endText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 90)
                            Text(String(localized: "秒", bundle: appLocalizationBundle))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "保存", bundle: appLocalizationBundle)) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if os(macOS)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
            #else
            .background(.regularMaterial)
            #endif
        }
        #if os(macOS)
        .frame(width: 460, height: 380)
        #endif
    }

    private func save() {
        guard let startSec = Double(startText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let endSec = Double(endText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = String(localized: "请输入有效的起止时间。", bundle: appLocalizationBundle)
            return
        }
        guard startSec >= 0 else {
            errorMessage = String(localized: "开始时间必须大于或等于 0 秒。", bundle: appLocalizationBundle)
            return
        }
        guard endSec > startSec else {
            errorMessage = String(localized: "结束时间必须大于开始时间。", bundle: appLocalizationBundle)
            return
        }

        do {
            let startMs = try SubtitleTimeOffset.milliseconds(from: startSec)
            let endMs = try SubtitleTimeOffset.milliseconds(from: endSec)
            try onSave(startMs, endMs)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 3. 拆分字幕表单
struct SplitSubtitleSheet: View {
    let cue: SubtitleCue
    let onSave: (Int64, String, String, String, String) throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var splitSecondsText: String
    @State private var firstSource: String
    @State private var secondSource: String
    @State private var firstTranslation: String
    @State private var secondTranslation: String
    @State private var errorMessage: String?

    init(cue: SubtitleCue, onSave: @escaping (Int64, String, String, String, String) throws -> Void) {
        self.cue = cue
        self.onSave = onSave

        let midSec = Double(cue.startMilliseconds + cue.endMilliseconds) / 2000.0
        _splitSecondsText = State(initialValue: String(format: "%.3f", midSec))

        let (s1, s2) = Self.splitTextAtMidpoint(cue.sourceText)
        _firstSource = State(initialValue: s1)
        _secondSource = State(initialValue: s2)

        if case .succeeded(let trans, _) = cue.translation {
            let (t1, t2) = Self.splitTextAtMidpoint(trans)
            _firstTranslation = State(initialValue: t1)
            _secondTranslation = State(initialValue: t2)
        } else {
            _firstTranslation = State(initialValue: "")
            _secondTranslation = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.voxlineAccent.opacity(0.12))
                    Image(systemName: "scissors")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.voxlineAccent)
                }
                .frame(width: 24, height: 24)
                Text(String(localized: "拆分字幕", bundle: appLocalizationBundle))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if os(macOS)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
            #else
            .background(.regularMaterial)
            #endif

            Form {
                Section(String(localized: "拆分时间点", bundle: appLocalizationBundle)) {
                    LabeledContent(String(localized: "时间点", bundle: appLocalizationBundle)) {
                        HStack(spacing: 4) {
                            TextField("", text: $splitSecondsText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 90)
                            Text(String(localized: "秒", bundle: appLocalizationBundle))
                                .foregroundStyle(.secondary)
                        }
                    }
                    let startStr = TimecodeFormatter.formatTimestamp(milliseconds: cue.startMilliseconds)
                    let endStr = TimecodeFormatter.formatTimestamp(milliseconds: cue.endMilliseconds)
                    Text(String(format: String(localized: "原时间：%@ – %@", bundle: appLocalizationBundle), locale: .current, startStr, endStr))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "前半句", bundle: appLocalizationBundle)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "前半句原文", bundle: appLocalizationBundle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $firstSource)
                            .font(.body)
                            .frame(minHeight: 48, maxHeight: 85)
                            .padding(4)
                            .background(Color.voxlineTextBackground, in: .rect(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                    }

                    if cue.hasTranslation {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "前半句译文", bundle: appLocalizationBundle))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $firstTranslation)
                                .font(.body)
                                .frame(minHeight: 48, maxHeight: 85)
                                .padding(4)
                                .background(Color.voxlineTextBackground, in: .rect(cornerRadius: 6))
                                .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                        }
                    }
                }

                Section(String(localized: "后半句", bundle: appLocalizationBundle)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "后半句原文", bundle: appLocalizationBundle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $secondSource)
                            .font(.body)
                            .frame(minHeight: 48, maxHeight: 85)
                            .padding(4)
                            .background(Color.voxlineTextBackground, in: .rect(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                    }

                    if cue.hasTranslation {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "后半句译文", bundle: appLocalizationBundle))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $secondTranslation)
                                .font(.body)
                                .frame(minHeight: 48, maxHeight: 85)
                                .padding(4)
                                .background(Color.voxlineTextBackground, in: .rect(cornerRadius: 6))
                                .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "保存", bundle: appLocalizationBundle)) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(firstSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secondSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if os(macOS)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
            #else
            .background(.regularMaterial)
            #endif
        }
        #if os(macOS)
        .frame(width: 500, height: 560)
        #endif
    }

    private func save() {
        guard let splitSec = Double(splitSecondsText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = String(localized: "请输入有效的拆分时间点。", bundle: appLocalizationBundle)
            return
        }

        do {
            let atMs = try SubtitleTimeOffset.milliseconds(from: splitSec)
            guard atMs > cue.startMilliseconds, atMs < cue.endMilliseconds else {
                errorMessage = String(localized: "拆分时间点必须在原字幕起止时间之间。", bundle: appLocalizationBundle)
                return
            }
            let s1 = firstSource.trimmingCharacters(in: .whitespacesAndNewlines)
            let s2 = secondSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s1.isEmpty, !s2.isEmpty else {
                errorMessage = String(localized: "拆分后的两段原文均不能为空。", bundle: appLocalizationBundle)
                return
            }
            let t1 = firstTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
            let t2 = secondTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
            try onSave(atMs, s1, s2, t1, t2)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func splitTextAtMidpoint(_ text: String) -> (String, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }
        let count = trimmed.count
        if count == 1 { return (trimmed, "") }

        let separators: [Character] = ["，", "。", "！", "？", ",", ".", "!", "?", " ", "、", "；", ";"]
        var bestIndex: String.Index? = nil
        var minDistance = count

        for sep in separators {
            var searchStart = trimmed.startIndex
            while let range = trimmed[searchStart...].firstRange(of: String(sep)) {
                let dist = abs(trimmed.distance(from: trimmed.startIndex, to: range.upperBound) - (count / 2))
                if dist < minDistance {
                    minDistance = dist
                    bestIndex = range.upperBound
                }
                searchStart = range.upperBound
                if searchStart == trimmed.endIndex { break }
            }
        }

        let splitAt = bestIndex ?? trimmed.index(trimmed.startIndex, offsetBy: max(1, count / 2))
        let first = String(trimmed[..<splitAt]).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(trimmed[splitAt...]).trimmingCharacters(in: .whitespacesAndNewlines)

        if first.isEmpty || second.isEmpty {
            let half = max(1, count / 2)
            let idx = trimmed.index(trimmed.startIndex, offsetBy: half)
            return (String(trimmed[..<idx]), String(trimmed[idx...]))
        }
        return (first, second)
    }
}

// MARK: - 4. 合并相邻字幕表单
struct MergeSubtitlesSheet: View {
    let cues: [SubtitleCue]
    let onSave: (String, String) throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var mergedSource: String
    @State private var mergedTranslation: String
    @State private var errorMessage: String?

    init(cues: [SubtitleCue], onSave: @escaping (String, String) throws -> Void) {
        self.cues = cues
        self.onSave = onSave

        _mergedSource = State(initialValue: cues.map(\.sourceText).joined(separator: " "))
        let translations = cues.compactMap { cue -> String? in
            if case .succeeded(let t, _) = cue.translation {
                return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : t
            }
            return nil
        }
        _mergedTranslation = State(initialValue: translations.count == cues.count ? translations.joined(separator: " ") : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.voxlineAccent.opacity(0.12))
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.voxlineAccent)
                }
                .frame(width: 24, height: 24)
                Text(String(localized: "合并字幕", bundle: appLocalizationBundle))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if os(macOS)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
            #else
            .background(.regularMaterial)
            #endif

            Form {
                Section(String(localized: "合并范围", bundle: appLocalizationBundle)) {
                    if let first = cues.first, let last = cues.last {
                        LabeledContent(String(localized: "起止时间", bundle: appLocalizationBundle)) {
                            let startStr = TimecodeFormatter.formatTimestamp(milliseconds: first.startMilliseconds)
                            let endStr = TimecodeFormatter.formatTimestamp(milliseconds: last.endMilliseconds)
                            Text("\(startStr) – \(endStr)")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(String(localized: "合并条数", bundle: appLocalizationBundle)) {
                        Text(String(localized: "\(cues.count) 句", bundle: appLocalizationBundle))
                            .foregroundStyle(.secondary)
                    }
                }

                Section(String(localized: "合并后内容", bundle: appLocalizationBundle)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "合并后原文", bundle: appLocalizationBundle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $mergedSource)
                            .font(.body)
                            .frame(minHeight: 56, maxHeight: 110)
                            .padding(4)
                            .background(Color.voxlineTextBackground, in: .rect(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "合并后译文（选填）", bundle: appLocalizationBundle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $mergedTranslation)
                            .font(.body)
                            .frame(minHeight: 56, maxHeight: 110)
                            .padding(4)
                            .background(Color.voxlineTextBackground, in: .rect(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "保存", bundle: appLocalizationBundle)) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(mergedSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if os(macOS)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
            #else
            .background(.regularMaterial)
            #endif
        }
        #if os(macOS)
        .frame(width: 480, height: 460)
        #endif
    }

    private func save() {
        let trimmedSource = mergedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            errorMessage = String(localized: "原文内容不能为空。", bundle: appLocalizationBundle)
            return
        }
        let trimmedTrans = mergedTranslation.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try onSave(trimmedSource, trimmedTrans)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
