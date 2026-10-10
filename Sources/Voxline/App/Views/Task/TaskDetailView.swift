#if os(macOS)
import VoxlineWorkflow
import SwiftUI
import VoxlineCore

public struct TaskDetailView: View {
    let task: ProcessingTask
    @Binding var isConfiguring: Bool
    @Binding var selectedMediaID: UUID?

    @State private var queue = TaskProcessingQueue.shared
    @State private var syncSettings = TaskSyncCoordinator.shared
    @State private var showConflictSheet = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?

    public init(task: ProcessingTask, isConfiguring: Binding<Bool>, selectedMediaID: Binding<UUID?>) {
        self.task = task
        _isConfiguring = isConfiguring
        _selectedMediaID = selectedMediaID
    }

    private var fileState: TaskSyncCoordinator.FileState? {
        TaskLibrary.shared.url(for: task.id).flatMap { syncSettings.fileStates[$0.standardizedFileURL] }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if fileState == .conflict {
                    conflictBanner
                }

                // Compact Metrics Bar
                compactMetricsBar

                // Media processing queue
                mediaQueue
            }
            .padding(24)
            if task.items.isEmpty {
                Text(String(localized: "请先添加本地音视频。", bundle: appLocalizationBundle)).font(.callout).foregroundStyle(.secondary).padding()
            }
            if let error = queue.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding()
            }
        }
        .sheet(isPresented: $showConflictSheet) {
            TaskConflictResolutionSheet(taskID: task.id, draftTask: task) {
                syncSettings.refresh()
            }
        }
        .alert(String(localized: "提示", bundle: appLocalizationBundle), isPresented: Binding(
            get: { noticeMessage != nil }, set: { if !$0 { noticeMessage = nil } }
        )) {
            Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) { noticeMessage = nil }
        } message: { Text(noticeMessage ?? "") }
        .alert(String(localized: "处理未开始或操作失败", bundle: appLocalizationBundle), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var conflictBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "此任务存在云端冲突版本", bundle: appLocalizationBundle))
                    .font(.subheadline.bold())
                Text(String(localized: "检测到其他设备保存的冲突文档，请选择保留版本或保存草稿副本。", bundle: appLocalizationBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(String(localized: "解决冲突…", bundle: appLocalizationBundle)) {
                showConflictSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    // MARK: - Compact Metrics Bar
    private var compactMetricsBar: some View {
        HStack(spacing: 20) {
            HStack(spacing: 6) {
                Image(systemName: "film.stack")
                    .foregroundStyle(.secondary)
                Text(String(localized: "\(task.items.count) 媒体", bundle: appLocalizationBundle))
                    .font(.subheadline.weight(.medium))
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(localized: "\(task.completedCount) 完成", bundle: appLocalizationBundle))
                    .font(.subheadline.weight(.medium))
            }

            if task.failedCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(String(localized: "\(task.failedCount) 失败", bundle: appLocalizationBundle))
                        .font(.subheadline.weight(.medium))
                }
            }

            let totalCues = task.items.reduce(0) { $0 + $1.cues.count }
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(.secondary)
                Text(String(localized: "\(totalCues) 句字幕", bundle: appLocalizationBundle))
                    .font(.subheadline.weight(.medium))
            }

            Spacer()

            if let state = fileState {
                SyncFileStatusBadge(state: state)
            }

            if !task.items.isEmpty && task.completedCount < task.items.count {
                let progress = Double(task.completedCount) / Double(task.items.count)
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 100)
                    Text(String(format: "%.0f%%", progress * 100))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlassSurface(cornerRadius: 12)
    }

    // MARK: - Media processing queue
    private var mediaQueue: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(String(localized: "媒体列表", bundle: appLocalizationBundle), systemImage: "film.stack")
                    .font(.headline)
                Spacer()
            }

            if task.items.isEmpty {
                ContentUnavailableView(
                    String(localized: "暂无媒体", bundle: appLocalizationBundle),
                    systemImage: "film.stack",
                    description: Text(String(localized: "请点击右上角“调整参数”添加音视频。", bundle: appLocalizationBundle))
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(task.items.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 0) {
                            HStack(alignment: .center, spacing: 12) {
                                // Index
                                Text(String(format: "%02d", index + 1))
                                    .font(.caption2.monospacedDigit().bold())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)

                                // Media Kind Icon
                                Image(systemName: item.kind == .video ? "film" : "waveform")
                                    .font(.headline)
                                    .foregroundStyle(item.kind == .video ? .blue : .purple)

                                // Title & Meta
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .lineLimit(1)

                                    HStack(spacing: 8) {
                                        if let media = item.media {
                                            Text(TimecodeFormatter.formatDuration(milliseconds: media.durationMilliseconds))
                                                .font(.caption2.monospacedDigit())
                                            Text(String(localized: "音轨 \(media.audioTrackID)", bundle: appLocalizationBundle))
                                            Text(String(localized: "\(item.cues.count) 句字幕", bundle: appLocalizationBundle))
                                        } else {
                                            Text(String(localized: "未关联文件", bundle: appLocalizationBundle)).foregroundStyle(.red)
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    if queue.taskID == task.id, queue.mediaID == item.id {
                                        Text(queue.isCancelling ? String(localized: "正在取消，等待当前操作结束", bundle: appLocalizationBundle) : queue.progressText ?? String(localized: "处理中", bundle: appLocalizationBundle))
                                            .font(.caption2).foregroundStyle(.tint)
                                        if let wait = queue.translationRetryWait, !queue.isCancelling {
                                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                                Text(wait.label(at: context.date))
                                                    .font(.caption2.monospacedDigit()).foregroundStyle(.primary)
                                            }
                                        }
                                        if let fraction = queue.extractionFraction {
                                            ProgressView(value: fraction).frame(width: 180)
                                        }
                                    }
                                }

                                Spacer()

                                // Xcode Step Pipeline Badge (Audio -> Transcription -> Translation -> Ready)
                                MediaProcessingStepsView(
                                    item: item,
                                    hasTranslation: task.parameters.translation != nil,
                                    provider: task.parameters.transcription.provider
                                )

                                // In-line Action Buttons
                                HStack(spacing: 6) {
                                    if item.status.isRetryable {
                                        Button(item.status.isTranslationPaused ? String(localized: "继续翻译", bundle: appLocalizationBundle) : String(localized: "重试", bundle: appLocalizationBundle), systemImage: "arrow.clockwise") {
                                            do { try queue.start(taskID: task.id, mediaID: item.id) }
                                            catch { errorMessage = error.localizedDescription }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(queue.taskID != nil || task.items.isEmpty)
                                    }

                                    if queue.taskID == task.id, queue.isScheduled(mediaID: item.id) {
                                        Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                                            do { try queue.cancel(mediaID: item.id) }
                                            catch { errorMessage = error.localizedDescription }
                                        }
                                        .controlSize(.small)
                                        .disabled(queue.isCancelling && queue.mediaID == item.id)
                                    }

                                    Button {
                                        selectedMediaID = item.id
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(String(localized: "校对", bundle: appLocalizationBundle))
                                            Image(systemName: "chevron.right")
                                                .font(.caption2.weight(.bold))
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)

                            // Inline Failure Diagnosis Drawer
                            if case .translationPaused(let reason) = item.status {
                                Label {
                                    Text(String(localized: "翻译暂停，成果已保存。\(reason) 可稍后继续翻译，或进入校对导出原文。", bundle: appLocalizationBundle))
                                        .foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: "pause.circle").foregroundStyle(.orange)
                                }
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                            }
                            if case .failed(let reason) = item.status {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.octagon.fill")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                    Text(String(localized: "失败原因：\(reason)", bundle: appLocalizationBundle))
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.08))
                            }
                        }

                        if index < task.items.count - 1 {
                            Divider()
                        }
                    }
                }
                .liquidGlassSurface(cornerRadius: 12)
            }
        }
    }
}

#endif
