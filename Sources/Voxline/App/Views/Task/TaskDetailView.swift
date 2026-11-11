#if os(macOS)
import VoxlineWorkflow
import SwiftUI
import VoxlineCore

public struct TaskDetailView: View {
    let task: ProcessingTask
    @Binding var selectedMediaID: UUID?

    @State private var queue = TaskProcessingQueue.shared
    @State private var syncSettings = TaskSyncCoordinator.shared
    @State private var showConflictSheet = false
    @State private var errorMessage: String?

    public init(task: ProcessingTask, selectedMediaID: Binding<UUID?>) {
        self.task = task
        _selectedMediaID = selectedMediaID
    }

    private var fileState: TaskSyncCoordinator.FileState? {
        TaskLibrary.shared.url(for: task.id).flatMap { syncSettings.fileStates[$0.standardizedFileURL] }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if fileState == .conflict {
                    HStack(spacing: 12) {
                        Label(String(localized: "此任务存在云端冲突版本", bundle: appLocalizationBundle), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(String(localized: "解决冲突…", bundle: appLocalizationBundle)) {
                            showConflictSheet = true
                        }
                        .disabled(queue.taskID == task.id)
                    }
                    .font(.callout)
                }

                if let error = queue.errorMessage(for: task.id) {
                    TaskFailureDisclosure(message: error, tint: .red)
                }

                HStack(spacing: 12) {
                    Text(String(localized: "\(task.items.count) 媒体", bundle: appLocalizationBundle))
                    if case .running = task.status {
                        Text(String(localized: "\(task.completedCount) 完成", bundle: appLocalizationBundle))
                    }
                    if task.failedCount > 0 {
                        Text(String(localized: "\(task.failedCount) 失败", bundle: appLocalizationBundle))
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    if let state = fileState { SyncFileStatusBadge(state: state) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

                if task.items.isEmpty {
                    ContentUnavailableView(String(localized: "暂无媒体", bundle: appLocalizationBundle), systemImage: "film.stack")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(task.items.enumerated()), id: \.element.id) { index, item in
                            TaskMediaRow(
                                taskID: task.id,
                                item: item,
                                hasTranslation: task.parameters.translation != nil,
                                provider: task.parameters.transcription.provider,
                                onOpen: { selectedMediaID = item.id },
                                onError: { errorMessage = $0 }
                            )
                            if index < task.items.count - 1 {
                                Divider().padding(.leading, 44).padding(.trailing, 12)
                            }
                        }
                    }
                    .padding(4)
                    .nativeControlSurface(cornerRadius: 14)
                }
            }
            .frame(maxWidth: 960)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showConflictSheet) {
            TaskConflictResolutionSheet(taskID: task.id, draftTask: task) { syncSettings.refresh() }
        }
        .alert(String(localized: "处理未开始或操作失败", bundle: appLocalizationBundle), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct TaskMediaRow: View {
    let taskID: UUID
    let item: TaskMediaItem
    let hasTranslation: Bool
    let provider: TranscriptionSettings.Provider
    let onOpen: () -> Void
    let onError: (String) -> Void
    @State private var queue = TaskProcessingQueue.shared
    @State private var isHovered = false
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        Image(systemName: item.kind == .video ? "film" : "waveform")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .help(item.title)
                            if let media = item.media {
                                Text(TimecodeFormatter.formatDuration(milliseconds: media.durationMilliseconds))
                                    .monospacedDigit()
                            } else {
                                Text(String(localized: "未关联文件", bundle: appLocalizationBundle))
                                    .foregroundStyle(.red)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        StatusSignal(mediaStatus: item.status)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.status.label)
                .accessibilityHint(String(localized: "进入校对", bundle: appLocalizationBundle))

                if item.status.isRetryable {
                    Button {
                        do { try queue.start(taskID: taskID, mediaID: item.id) }
                        catch { onError(error.localizedDescription) }
                    } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                    .help(item.status.isTranslationPaused ? String(localized: "继续翻译", bundle: appLocalizationBundle) : String(localized: "重试", bundle: appLocalizationBundle))
                    .accessibilityLabel(item.status.isTranslationPaused ? String(localized: "继续翻译", bundle: appLocalizationBundle) : String(localized: "重试", bundle: appLocalizationBundle))
                    .disabled(queue.taskID != nil)
                }
                if queue.taskID == taskID, queue.isScheduled(mediaID: item.id) {
                    Button {
                        do { try queue.cancel(mediaID: item.id) }
                        catch { onError(error.localizedDescription) }
                    } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .help(String(localized: "取消处理", bundle: appLocalizationBundle))
                    .accessibilityLabel(String(localized: "取消处理", bundle: appLocalizationBundle))
                    .disabled(queue.isCancelling && queue.mediaID == item.id)
                }
                Button { showingDetails = true } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }
                .help(String(localized: "媒体详情", bundle: appLocalizationBundle))
                .accessibilityLabel(String(localized: "媒体详情", bundle: appLocalizationBundle))
                .popover(isPresented: $showingDetails) { mediaDetails }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.voxlineAccent.opacity(0.04) : Color.clear)
            }
            .onHover { isHovered = $0 }

            MediaQueueProgress(taskID: taskID, mediaID: item.id)

            switch item.status {
            case .failed(let reason):
                TaskFailureDisclosure(message: reason, tint: .red)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            case .translationPaused(let reason):
                TaskFailureDisclosure(message: String(localized: "翻译暂停：\(reason)", bundle: appLocalizationBundle), tint: .orange)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            default: EmptyView()
            }
        }
    }

    private var mediaDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title).font(.headline).textSelection(.enabled)
            if let media = item.media {
                Text(String(localized: "音轨 \(media.audioTrackID)", bundle: appLocalizationBundle))
            }
            Text(String(localized: "\(item.cues.count) 句字幕", bundle: appLocalizationBundle))
            Divider()
            Text(String(localized: "处理阶段", bundle: appLocalizationBundle)).font(.subheadline.weight(.medium))
            if item.importedSubtitleOrigin != nil {
                LabeledContent(String(localized: "导入原文", bundle: appLocalizationBundle)) {
                    StatusSignal(kind: StatusSignalKind(stepState: .completed))
                }
            } else {
                LabeledContent(String(localized: "提取音频", bundle: appLocalizationBundle)) {
                    StatusSignal(kind: StatusSignalKind(stepState: item.extractionState))
                }
                LabeledContent(provider == .whisperKit ? String(localized: "本地转写", bundle: appLocalizationBundle) : String(localized: "云端转写", bundle: appLocalizationBundle)) {
                    StatusSignal(kind: StatusSignalKind(stepState: item.transcriptionState))
                }
            }
            if hasTranslation {
                LabeledContent(String(localized: "字幕翻译", bundle: appLocalizationBundle)) {
                    StatusSignal(kind: StatusSignalKind(stepState: item.translationState))
                }
            }
        }
        .font(.callout)
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}

private struct MediaQueueProgress: View {
    let taskID: UUID
    let mediaID: UUID
    @State private var queue = TaskProcessingQueue.shared

    var body: some View {
        if queue.taskID == taskID, queue.mediaID == mediaID {
            VStack(alignment: .leading, spacing: 4) {
                Text(queue.isCancelling ? String(localized: "正在取消，等待当前操作结束", bundle: appLocalizationBundle) : queue.progressText ?? String(localized: "处理中", bundle: appLocalizationBundle))
                    .foregroundStyle(.tint)
                if let wait = queue.translationRetryWait, !queue.isCancelling {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(wait.label(at: context.date)).monospacedDigit()
                    }
                }
                if let fraction = queue.extractionFraction {
                    ProgressView(value: fraction).frame(maxWidth: 180)
                }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 44)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        }
    }
}

private struct TaskFailureDisclosure: View {
    let message: String
    let tint: Color

    var body: some View {
        DisclosureGroup {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label {
                Text(message).lineLimit(1)
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(tint)
            }
            .font(.callout)
        }
        .tint(tint)
    }
}
#endif
