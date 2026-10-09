import SwiftUI
import VoxlineCore
import VoxlineMedia
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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

// MARK: - 5. 跨平台剪贴板与时间辅助函数
func copyCueTextToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #elseif os(iOS)
    UIPasteboard.general.string = text
    #endif
}

func formatCueTimestamp(_ milliseconds: Int64) -> String {
    let totalSeconds = milliseconds / 1000
    let ms = milliseconds % 1000
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d.%03d", minutes, seconds, ms)
}

// MARK: - 6. 共享结构编辑状态与弹窗修饰符
struct InsertingTimePayload: Identifiable {
    let id = UUID()
    let time: Double

    init(time: Double) {
        self.time = time
    }
}

@Observable @MainActor
final class SubtitleStructureState {
    var insertingStartTime: Double?
    var timingCue: SubtitleCue?
    var splittingCue: SubtitleCue?
    var mergingCues: [SubtitleCue]?

    init() {}

    func insert(at seconds: Double) {
        insertingStartTime = seconds
    }

    func adjustTiming(for cue: SubtitleCue) {
        timingCue = cue
    }

    func split(cue: SubtitleCue) {
        splittingCue = cue
    }

    func merge(cues: [SubtitleCue]) {
        mergingCues = cues
    }
}

struct SubtitleStructureSheetsModifier: ViewModifier {
    @Bindable var state: SubtitleStructureState
    let item: TaskMediaItem
    let session: ProofreadingSession
    let onCommit: (TaskMediaItem, TaskMediaItem) throws -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { state.insertingStartTime.map { InsertingTimePayload(time: $0) } },
                set: { state.insertingStartTime = $0?.time }
            )) { payload in
                InsertSubtitleSheet(initialStartSeconds: payload.time) { newCue in
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

// MARK: - 7. 共享播放控制条组件
struct ProofreadingPlayerControls: View {
    @Bindable var playback: MediaPlaybackController
    var style: Style = .capsule

    public enum Style {
        case capsule
        case card
    }

    init(playback: MediaPlaybackController, style: Style = .capsule) {
        self.playback = playback
        self.style = style
    }

    var body: some View {
        switch style {
        case .capsule:
            capsuleContent
        case .card:
            cardContent
        }
    }

    private var capsuleContent: some View {
        HStack(spacing: 14) {
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? String(localized: "暂停", bundle: appLocalizationBundle) : String(localized: "播放", bundle: appLocalizationBundle))

            Button {
                playback.seekRelative(by: -5.0)
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(String(localized: "快退 5 秒", bundle: appLocalizationBundle))

            Button {
                playback.seekRelative(by: 5.0)
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(String(localized: "快进 5 秒", bundle: appLocalizationBundle))

            Text(playback.formattedCurrentTime)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)

            Slider(
                value: Binding(
                    get: { playback.currentTimeSeconds },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.durationSeconds, 1.0)
            )
            .controlSize(.mini)
            .accessibilityLabel(String(localized: "播放进度", bundle: appLocalizationBundle))
            .frame(minWidth: 100)

            Text(playback.formattedDuration)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)

            speedMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .liquidGlassCapsule()
        .disabled(!playback.isReady)
    }

    private var cardContent: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(playback.formattedCurrentTime)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { playback.currentTimeSeconds },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.durationSeconds, 0.1)
                )
                .tint(Color.voxlineAccent)
                .disabled(!playback.isReady)

                Text(playback.formattedDuration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)

            HStack(spacing: 30) {
                Button {
                    playback.seekRelative(by: -5)
                } label: {
                    Image(systemName: "gobackward.5")
                        .font(.title3)
                }

                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.voxlineAccent)
                }

                Button {
                    playback.seekRelative(by: 5)
                } label: {
                    Image(systemName: "goforward.5")
                        .font(.title3)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    private var speedMenu: some View {
        Menu {
            Button("0.5x") { playback.setRate(0.5) }
            Button("0.75x") { playback.setRate(0.75) }
            Button(String(localized: "1.0x (正常)", bundle: appLocalizationBundle)) { playback.setRate(1.0) }
            Button("1.25x") { playback.setRate(1.25) }
            Button("1.5x") { playback.setRate(1.5) }
            Button("2.0x") { playback.setRate(2.0) }
        } label: {
            Text(String(format: "%.2fx", playback.playbackRate))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: .capsule)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
    }
}

// MARK: - 8. 共享字幕行组件
struct ProofreadingCueRow: View {
    let cue: SubtitleCue
    let item: TaskMediaItem
    @Bindable var session: ProofreadingSession
    let isActive: Bool
    let isHovered: Bool
    let isEditing: Bool
    let isPast: Bool
    let canRetranslate: Bool
    let isTaskRunning: Bool

    let onSeek: (Int64) -> Void
    let onRetranslate: (SubtitleCue) -> Void
    let onBeginEdit: (SubtitleCue) -> Void
    let onSaveEdit: (() -> Void)?
    let onCancelEdit: (() -> Void)?
    let onAdjustTiming: (SubtitleCue) -> Void
    let onSplit: (SubtitleCue) -> Void
    let onMerge: ([SubtitleCue]) -> Void
    let onDelete: (SubtitleCue) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        cue: SubtitleCue,
        item: TaskMediaItem,
        session: ProofreadingSession,
        isActive: Bool,
        isHovered: Bool = false,
        isEditing: Bool = false,
        isPast: Bool = false,
        canRetranslate: Bool = true,
        isTaskRunning: Bool = false,
        onSeek: @escaping (Int64) -> Void,
        onRetranslate: @escaping (SubtitleCue) -> Void,
        onBeginEdit: @escaping (SubtitleCue) -> Void,
        onSaveEdit: (() -> Void)? = nil,
        onCancelEdit: (() -> Void)? = nil,
        onAdjustTiming: @escaping (SubtitleCue) -> Void,
        onSplit: @escaping (SubtitleCue) -> Void,
        onMerge: @escaping ([SubtitleCue]) -> Void,
        onDelete: @escaping (SubtitleCue) -> Void
    ) {
        self.cue = cue
        self.item = item
        self.session = session
        self.isActive = isActive
        self.isHovered = isHovered
        self.isEditing = isEditing
        self.isPast = isPast
        self.canRetranslate = canRetranslate
        self.isTaskRunning = isTaskRunning
        self.onSeek = onSeek
        self.onRetranslate = onRetranslate
        self.onBeginEdit = onBeginEdit
        self.onSaveEdit = onSaveEdit
        self.onCancelEdit = onCancelEdit
        self.onAdjustTiming = onAdjustTiming
        self.onSplit = onSplit
        self.onMerge = onMerge
        self.onDelete = onDelete
    }

    public var body: some View {
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
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                topBar
                textContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            isActive
                ? Color.voxlineActiveCueBackground
                : (isHovered ? Color.secondary.opacity(0.06) : Color.clear),
            in: .rect(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive ? Color.voxlineActiveCueBorder : Color.clear, lineWidth: 1)
        )
        .opacity(isActive ? 1.0 : (isHovered ? 0.95 : (isPast ? 0.40 : 0.70)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isActive)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
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
                        .font(.system(size: 9))
                    Text(formatCueTimestamp(cue.startMilliseconds))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    isActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                    in: .capsule
                )
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            if isEditing {
                if let onCancelEdit {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                        onCancelEdit()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                if let onSaveEdit {
                    Button {
                        onSaveEdit()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help(String(localized: "保存", bundle: appLocalizationBundle))
                }
            } else if !session.isSelecting {
                Button {
                    onBeginEdit(cue)
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "编辑字幕", bundle: appLocalizationBundle))
                .disabled(session.editingSnapshot?.id != nil)

                if canRetranslate {
                    Button {
                        onRetranslate(cue)
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "重新翻译", bundle: appLocalizationBundle))
                    .disabled(session.editingSnapshot?.id != nil || isTaskRunning)
                }

                Menu {
                    actionMenuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                TextField(String(localized: "原文内容", bundle: appLocalizationBundle), text: $session.sourceDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16, weight: .medium))

                TextField(String(localized: "译文内容", bundle: appLocalizationBundle), text: $session.translationDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
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
                            .foregroundStyle(session.previewKind == .bilingual ? .yellow : .primary)
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
            onBeginEdit(cue)
        } label: {
            Label(String(localized: "编辑文字", bundle: appLocalizationBundle), systemImage: "pencil")
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

        if let currentIndex = item.cues.firstIndex(where: { $0.id == cue.id }),
           currentIndex + 1 < item.cues.count {
            let nextCue = item.cues[currentIndex + 1]
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
            Label(String(localized: "删除字幕", bundle: appLocalizationBundle), systemImage: "trash")
        }
        .disabled(isTaskRunning || session.editingSnapshot?.id != nil)
    }
}
