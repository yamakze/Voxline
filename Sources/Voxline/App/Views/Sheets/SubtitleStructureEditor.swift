import SwiftUI
import VoxlineCore

struct IdentifiableCueList: Identifiable {
    var id: [UUID] { cues.map(\.id) }
    let cues: [SubtitleCue]

    init(cues: [SubtitleCue]) {
        self.cues = cues
    }
}

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
        NavigationStack {
            Form {
                Section(String(localized: "时间轴（秒）", bundle: appLocalizationBundle)) {
                    HStack {
                        Text(String(localized: "开始时间（秒）", bundle: appLocalizationBundle))
                        Spacer()
                        TextField("0.000", text: $startText)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    HStack {
                        Text(String(localized: "结束时间（秒）", bundle: appLocalizationBundle))
                        Spacer()
                        TextField("0.000", text: $endText)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                }

                Section(String(localized: "字幕内容", bundle: appLocalizationBundle)) {
                    TextField(String(localized: "原文内容", bundle: appLocalizationBundle), text: $sourceText, axis: .vertical)
                        .lineLimit(2...5)
                    TextField(String(localized: "译文内容（选填）", bundle: appLocalizationBundle), text: $translationText, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "添加字幕", bundle: appLocalizationBundle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存", bundle: appLocalizationBundle)) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 300)
            #endif
        }
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
        NavigationStack {
            Form {
                Section(String(localized: "字幕预览", bundle: appLocalizationBundle)) {
                    Text(cue.sourceText)
                        .font(.body)
                    if case .succeeded(let trans, _) = cue.translation {
                        Text(trans)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(String(localized: "起止时间（秒）", bundle: appLocalizationBundle)) {
                    HStack {
                        Text(String(localized: "开始时间（秒）", bundle: appLocalizationBundle))
                        Spacer()
                        TextField("0.000", text: $startText)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    HStack {
                        Text(String(localized: "结束时间（秒）", bundle: appLocalizationBundle))
                        Spacer()
                        TextField("0.000", text: $endText)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "调整时间", bundle: appLocalizationBundle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存", bundle: appLocalizationBundle)) { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 280)
            #endif
        }
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
        NavigationStack {
            Form {
                Section(String(localized: "拆分时间点（秒）", bundle: appLocalizationBundle)) {
                    HStack {
                        Text(String(localized: "拆分时间点（秒）", bundle: appLocalizationBundle))
                        Spacer()
                        TextField("0.000", text: $splitSecondsText)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    Text(String(format: String(localized: "原范围：%.3f 秒 → %.3f 秒", bundle: appLocalizationBundle), locale: .current, Double(cue.startMilliseconds)/1000.0, Double(cue.endMilliseconds)/1000.0))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "前半句", bundle: appLocalizationBundle)) {
                    TextField(String(localized: "前半句原文", bundle: appLocalizationBundle), text: $firstSource, axis: .vertical)
                        .lineLimit(2...4)
                    if cue.hasTranslation {
                        TextField(String(localized: "前半句译文", bundle: appLocalizationBundle), text: $firstTranslation, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }

                Section(String(localized: "后半句", bundle: appLocalizationBundle)) {
                    TextField(String(localized: "后半句原文", bundle: appLocalizationBundle), text: $secondSource, axis: .vertical)
                        .lineLimit(2...4)
                    if cue.hasTranslation {
                        TextField(String(localized: "后半句译文", bundle: appLocalizationBundle), text: $secondTranslation, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "拆分字幕", bundle: appLocalizationBundle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存", bundle: appLocalizationBundle)) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(firstSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secondSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 380)
            #endif
        }
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
        NavigationStack {
            Form {
                Section(String(localized: "合并范围", bundle: appLocalizationBundle)) {
                    if let first = cues.first, let last = cues.last {
                        HStack {
                            Text(String(localized: "起止时间", bundle: appLocalizationBundle))
                            Spacer()
                            Text(String(format: String(localized: "%.3f 秒 → %.3f 秒", bundle: appLocalizationBundle), locale: .current, Double(first.startMilliseconds)/1000.0, Double(last.endMilliseconds)/1000.0))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text(String(localized: "合并条数", bundle: appLocalizationBundle))
                        Spacer()
                        Text(String(localized: "\(cues.count) 句", bundle: appLocalizationBundle))
                            .foregroundStyle(.secondary)
                    }
                }

                Section(String(localized: "合并后内容", bundle: appLocalizationBundle)) {
                    TextField(String(localized: "合并后原文", bundle: appLocalizationBundle), text: $mergedSource, axis: .vertical)
                        .lineLimit(2...5)
                    TextField(String(localized: "合并后译文（选填）", bundle: appLocalizationBundle), text: $mergedTranslation, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "合并字幕", bundle: appLocalizationBundle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存", bundle: appLocalizationBundle)) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(mergedSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 320)
            #endif
        }
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
