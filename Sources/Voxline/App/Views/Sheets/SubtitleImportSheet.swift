import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

/// 共享字幕导入与匹配 Sheet，支持外挂 SRT / VTT 原文字幕导入，以及译文字幕导入与时间匹配。
public struct SubtitleImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: SubtitleImportSession
    @State private var showFilePicker = false
    @State private var selectedFile: SelectedSubtitleFile?
    @State private var showConfirmReplace = false
    @State private var errorMessage: String?
    @State private var selectingAssignment: AssignmentTargetSelection?

    private struct AssignmentTargetSelection: Identifiable {
        let id: UUID
    }

    private struct SelectedSubtitleFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    private let onCommitOriginal: ((SubtitleImportSelection, Bool, TaskMediaItem) throws -> Void)?
    private let onCommitTranslation: (([SubtitleTranslationAssignment], Bool, TaskMediaItem) throws -> Void)?
    private let resumingUnmatched: Bool

    /// 原文字幕导入（校对页）
    public init(item: TaskMediaItem,
                onCommit: @escaping (SubtitleImportSelection, Bool, TaskMediaItem) throws -> Void) {
        self._session = State(initialValue: SubtitleImportSession(item: item, role: .original))
        self.onCommitOriginal = onCommit
        self.onCommitTranslation = nil
        self.resumingUnmatched = false
    }

    /// 译文字幕导入（校对页）
    public init(item: TaskMediaItem,
                onCommit: @escaping ([SubtitleTranslationAssignment], Bool, TaskMediaItem) throws -> Void) {
        self._session = State(initialValue: SubtitleImportSession(item: item, role: .translation))
        self.onCommitOriginal = nil
        self.onCommitTranslation = onCommit
        self.resumingUnmatched = false
    }

    /// 继续匹配待匹配译文（校对页）
    public init(resumingItem: TaskMediaItem,
                onCommit: @escaping ([SubtitleTranslationAssignment], Bool, TaskMediaItem) throws -> Void) {
        self._session = State(initialValue: SubtitleImportSession(item: resumingItem, role: .translation, resumingUnmatched: true))
        self.onCommitOriginal = nil
        self.onCommitTranslation = onCommit
        self.resumingUnmatched = true
    }

    private var navigationTitleText: String {
        if resumingUnmatched {
            return String(localized: "继续匹配译文字幕", bundle: appLocalizationBundle)
        }
        switch session.role {
        case .original:
            return String(localized: "导入原文字幕", bundle: appLocalizationBundle)
        case .translation:
            return String(localized: "导入译文字幕", bundle: appLocalizationBundle)
        }
    }

    private var canCommit: Bool {
        if session.isReading { return false }
        switch session.role {
        case .original:
            return !session.entries.isEmpty && session.origin != nil
        case .translation:
            return !session.assignments.isEmpty
        }
    }

    /// 统计每个原文字幕被分配的次数，用于检测多对一合并
    private var cueAssignmentCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for assignment in session.assignments {
            if let cueID = assignment.cueID {
                counts[cueID, default: 0] += 1
            }
        }
        return counts
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if session.isReading {
                    readingLoadingView
                } else if session.origin == nil && !resumingUnmatched {
                    emptyFileSelectionView
                } else {
                    fileHeaderBar
                    Divider()
                    contentPreviewView
                }
            }
            .navigationTitle(navigationTitleText)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                        dismiss()
                    }
                    .accessibilityLabel(String(localized: "取消导入", bundle: appLocalizationBundle))
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成", bundle: appLocalizationBundle)) {
                        if session.replacesExisting { showConfirmReplace = true }
                        else { saveImportedSubtitles(replacingExisting: false) }
                    }
                    .disabled(!canCommit)
                    .accessibilityLabel(String(localized: "确认导入并保存", bundle: appLocalizationBundle))
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [
                    UTType(filenameExtension: "srt") ?? .plainText,
                    UTType(filenameExtension: "vtt") ?? .plainText,
                    .plainText
                ],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    selectedFile = .init(url: url)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .task(id: selectedFile?.id) {
                if let selectedFile { await session.readFile(selectedFile.url) }
            }
            .confirmationDialog(
                session.role == .original
                    ? String(localized: "覆盖已有原文字幕？", bundle: appLocalizationBundle)
                    : String(localized: "覆盖已有译文字幕？", bundle: appLocalizationBundle),
                isPresented: $showConfirmReplace,
                titleVisibility: .visible
            ) {
                Button(String(localized: "确认覆盖", bundle: appLocalizationBundle), role: .destructive) {
                    saveImportedSubtitles(replacingExisting: true)
                }
                Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
            } message: {
                Text(
                    session.role == .original
                        ? String(localized: "当前已有字幕将被新导入的字幕替换。", bundle: appLocalizationBundle)
                        : String(localized: "当前已有译文将被导入的匹配结果替换。", bundle: appLocalizationBundle)
                )
            }
            .sheet(item: $selectingAssignment) { target in
                if let index = session.assignments.firstIndex(where: { $0.id == target.id }) {
                    TargetCuePickerSheet(
                        assignment: session.assignments[index],
                        allCues: session.item.cues,
                        onSelect: { selectedCueID in
                            session.assignments[index].cueID = selectedCueID
                            selectingAssignment = nil
                        },
                        onDismiss: {
                            selectingAssignment = nil
                        }
                    )
                }
            }
            .alert(String(localized: "导入遇到问题", bundle: appLocalizationBundle), isPresented: Binding(
                get: { errorMessage != nil || session.errorMessage != nil },
                set: { if !$0 { errorMessage = nil; session.errorMessage = nil } }
            )) {
                Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) {
                    errorMessage = nil
                    session.errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? session.errorMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 460, idealHeight: 560)
        #endif
    }

    // MARK: - 未选择文件时的空状态选择区
    private var emptyFileSelectionView: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 64, height: 64)
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text(String(localized: "选择字幕文件", bundle: appLocalizationBundle))
                    .font(.headline)
                Text(String(localized: "支持 SRT、VTT 等外挂字幕格式", bundle: appLocalizationBundle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                showFilePicker = true
            } label: {
                Label(String(localized: "选择文件…", bundle: appLocalizationBundle), systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel(String(localized: "选择本地字幕文件", bundle: appLocalizationBundle))
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color.voxlineControlBackground.opacity(0.3))
    }

    // MARK: - 已选文件紧凑信息栏
    private var fileHeaderBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .font(.body)
                .foregroundStyle(Color.accentColor)

            if case .file(let fileName) = session.origin {
                Text(fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            } else if resumingUnmatched {
                Text(String(localized: "未分配译文", bundle: appLocalizationBundle))
                    .font(.subheadline.weight(.semibold))
            }

            Spacer()

            if !resumingUnmatched {
                Button {
                    showFilePicker = true
                } label: {
                    Text(String(localized: "更换文件…", bundle: appLocalizationBundle))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(String(localized: "选择本地字幕文件", bundle: appLocalizationBundle))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.voxlineControlBackground)
    }

    // MARK: - 读取中等待视图
    private var readingLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "正在解析字幕内容…", bundle: appLocalizationBundle))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 内容预览视图
    @ViewBuilder
    private var contentPreviewView: some View {
        switch session.role {
        case .original:
            originalEntriesPreview
        case .translation:
            translationAssignmentsPreview
        }
    }

    // MARK: - 原文条目预览
    private var originalEntriesPreview: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "共解析 \(session.entries.count) 条原文字幕", bundle: appLocalizationBundle))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.voxlineControlBackground.opacity(0.5))

            Divider()

            List(Array(session.entries.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(TimecodeFormatter.formatTimestamp(milliseconds: entry.startMilliseconds))
                            Text("→")
                            Text(TimecodeFormatter.formatTimestamp(milliseconds: entry.endMilliseconds))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                        Text(entry.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
    }

    // MARK: - 译文分配与匹配预览
    private var translationAssignmentsPreview: some View {
        VStack(spacing: 0) {
            HStack {
                let matched = session.matchedCount
                let total = session.assignments.count
                Text(String(localized: "已匹配 \(matched) / \(total) 条", bundle: appLocalizationBundle))
                    .font(.caption.bold())
                    .foregroundStyle(matched == total ? .green : .primary)

                Spacer()

                Text(String(localized: "待匹配译文", bundle: appLocalizationBundle))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.voxlineControlBackground.opacity(0.5))

            Divider()

            let counts = cueAssignmentCounts
            List(Array(session.assignments.enumerated()), id: \.element.id) { index, assignment in
                let targetCue = assignment.cueID.flatMap { session.cuesByID[$0] }
                let isMerged = (assignment.cueID != nil) && ((counts[assignment.cueID!] ?? 0) > 1)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit().bold())
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, alignment: .leading)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(TimecodeFormatter.formatTimestamp(milliseconds: assignment.entry.startMilliseconds))
                                Text("→")
                                Text(TimecodeFormatter.formatTimestamp(milliseconds: assignment.entry.endMilliseconds))
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                            Text(assignment.entry.text)
                                .font(.system(size: 14, weight: .medium))
                        }

                        Spacer()

                        if isMerged {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.merge")
                                Text(String(localized: "多对一合并", bundle: appLocalizationBundle))
                            }
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: .capsule)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(String(localized: "此条目将与相同目标的原文字幕合并", bundle: appLocalizationBundle))
                        }
                    }

                    // 目标原文字幕选择行（原生 Menu，不叠加手绘箭头）
                    HStack(spacing: 8) {
                        Image(systemName: assignment.cueID != nil ? "link" : "link.badge.plus")
                            .font(.caption)
                            .foregroundStyle(assignment.cueID != nil ? Color.accentColor : Color.secondary)

                        if let targetCue {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(String(localized: "对应原文：", bundle: appLocalizationBundle))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(targetCue.sourceText)
                                    .font(.caption.bold())
                                    .lineLimit(2)
                            }
                        } else {
                            Text(String(localized: "待匹配", bundle: appLocalizationBundle))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Spacer()

                        Menu {
                            Button(String(localized: "暂不匹配", bundle: appLocalizationBundle)) {
                                session.assignments[index].cueID = nil
                            }

                            if !assignment.candidateCueIDs.isEmpty {
                                Section(String(localized: "时间重叠推荐", bundle: appLocalizationBundle)) {
                                    ForEach(assignment.candidateCueIDs, id: \.self) { candidateID in
                                        if let cue = session.cuesByID[candidateID] {
                                            Button {
                                                session.assignments[index].cueID = candidateID
                                            } label: {
                                                Text("\(TimecodeFormatter.formatTimestamp(milliseconds: cue.startMilliseconds)) · \(cue.sourceText)")
                                            }
                                        }
                                    }
                                }
                            }

                            Button(String(localized: "在全部原文字幕中选择…", bundle: appLocalizationBundle)) {
                                selectingAssignment = .init(id: assignment.id)
                            }
                        } label: {
                            Text(assignment.cueID != nil ? String(localized: "更换目标", bundle: appLocalizationBundle) : String(localized: "选择目标", bundle: appLocalizationBundle))
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "选择匹配的原文字幕目标", bundle: appLocalizationBundle))
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
    }

    private func saveImportedSubtitles(replacingExisting: Bool) {
        do {
            switch session.role {
            case .original:
                let selection = try session.originalSelection()
                try onCommitOriginal?(selection, replacingExisting, session.item)
            case .translation:
                try onCommitTranslation?(session.assignments, replacingExisting, session.item)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 全部原文字幕挑选辅助 Sheet
private struct TargetCuePickerSheet: View {
    let assignment: SubtitleTranslationAssignment
    let allCues: [SubtitleCue]
    let onSelect: (UUID?) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private var filteredCues: [SubtitleCue] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return allCues
        }
        return allCues.filter { $0.sourceText.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 当前待匹配译文提示
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "当前译文：", bundle: appLocalizationBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(assignment.entry.text)
                        .font(.subheadline.bold())
                    HStack(spacing: 4) {
                        Text(TimecodeFormatter.formatTimestamp(milliseconds: assignment.entry.startMilliseconds))
                        Text("→")
                        Text(TimecodeFormatter.formatTimestamp(milliseconds: assignment.entry.endMilliseconds))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.voxlineControlBackground)

                Divider()

                List {
                    Button {
                        onSelect(nil)
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                            Text(String(localized: "保留为待匹配", bundle: appLocalizationBundle))
                                .foregroundStyle(.primary)
                            Spacer()
                            if assignment.cueID == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    ForEach(filteredCues) { cue in
                        Button {
                            onSelect(cue.id)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 4) {
                                        Text(TimecodeFormatter.formatTimestamp(milliseconds: cue.startMilliseconds))
                                        Text("→")
                                        Text(TimecodeFormatter.formatTimestamp(milliseconds: cue.endMilliseconds))
                                    }
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)

                                    Text(cue.sourceText)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                }
                                Spacer()
                                if assignment.cueID == cue.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText, prompt: Text(String(localized: "搜索原文字幕…", bundle: appLocalizationBundle)))
            }
            .navigationTitle(String(localized: "选择匹配原文字幕", bundle: appLocalizationBundle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭", bundle: appLocalizationBundle), action: onDismiss)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 400, idealHeight: 480)
        #endif
    }
}
