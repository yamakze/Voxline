#if os(macOS)
import VoxlineWorkflow
import SwiftUI
import VoxlineCore

public struct TaskDetailView: View {
    let task: ProcessingTask
    @Binding var isConfiguring: Bool
    @Binding var selectedMediaID: UUID?

    @State private var queue = TaskProcessingQueue.shared
    @State private var syncSettings = TaskSyncSettings.shared
    @State private var showConflictSheet = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var pendingCloudRetryItem: TaskMediaItem?
    @State private var showChangeCloudService = false

    public init(task: ProcessingTask, isConfiguring: Binding<Bool>, selectedMediaID: Binding<UUID?>) {
        self.task = task
        _isConfiguring = isConfiguring
        _selectedMediaID = selectedMediaID
    }

    private var fileState: TaskSyncSettings.FileState? {
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
                Text("请先添加本地音视频。").font(.callout).foregroundStyle(.secondary).padding()
            }
            if let error = queue.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding()
            }
        }
        .sheet(isPresented: $showConflictSheet) {
            TaskConflictResolutionSheet(taskID: task.id, draftTask: task) {
                TaskLibrary.shared.refresh()
                syncSettings.refresh()
            }
        }
        .sheet(isPresented: $showChangeCloudService) {
            ChangeCloudTranscriptionServiceSheet(task: task) { updated in
                try TaskLibrary.shared.save(updated)
                TaskLibrary.shared.refresh()
            }
        }
        .alert("提示", isPresented: Binding(
            get: { noticeMessage != nil }, set: { if !$0 { noticeMessage = nil } }
        )) {
            Button("好", role: .cancel) { noticeMessage = nil }
        } message: { Text(noticeMessage ?? "") }
        .alert("处理未开始或操作失败", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog(
            "确认开始云端转写？",
            isPresented: Binding(
                get: { pendingCloudRetryItem != nil },
                set: { if !$0 { pendingCloudRetryItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("确认并重试") {
                if let item = pendingCloudRetryItem {
                    pendingCloudRetryItem = nil
                    do { try queue.start(taskID: task.id, mediaID: item.id) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) { pendingCloudRetryItem = nil }
        } message: {
            if let item = pendingCloudRetryItem {
                let transcription = task.parameters.transcription
                let destination = transcription.cloud?.baseURL.absoluteString ?? "未配置服务"
                let lang = transcription.languageMode == .specified ? (transcription.languageCode ?? "指定语言") : "自动识别"
                Text("媒体：\(item.title)\n服务：\(destination)\n模型：\(transcription.modelID) · 语言：\(lang)\n将提取音轨并上传至该服务进行云端转写。")
            }
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("此任务存在云端冲突版本")
                    .font(.subheadline.bold())
                Text("检测到其他设备保存的冲突文档，请选择保留版本或保存草稿副本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("解决冲突…") {
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
                Text("\(task.items.count) 媒体")
                    .font(.subheadline.weight(.medium))
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(task.completedCount) 完成")
                    .font(.subheadline.weight(.medium))
            }

            if task.failedCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("\(task.failedCount) 失败")
                        .font(.subheadline.weight(.medium))
                }
            }

            let totalCues = task.items.reduce(0) { $0 + $1.cues.count }
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(.secondary)
                Text("\(totalCues) 句字幕")
                    .font(.subheadline.weight(.medium))
            }

            Spacer()

            if task.parameters.transcription.provider == .openAICompatible {
                Button("更换转写服务…") {
                    showChangeCloudService = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(queue.taskID == task.id || task.items.contains(where: { if case .running = $0.status { true } else { false } }))
            }

            if let state = fileState {
                SyncFileStatusBadge(state: state)
            }

            if !task.items.isEmpty {
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
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: .rect(cornerRadius: 10))
    }

    // MARK: - Media processing queue
    private var mediaQueue: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("媒体列表", systemImage: "film.stack")
                    .font(.headline)
                Spacer()
            }

            if task.items.isEmpty {
                ContentUnavailableView(
                    "流水线队列为空",
                    systemImage: "film.stack",
                    description: Text("请点击右上角“调整参数与媒体”导入音视频。")
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
                                            Text(String(format: "%.1fs", Double(media.durationMilliseconds) / 1000.0))
                                            Text("音轨 \(media.audioTrackID)")
                                            Text("\(item.cues.count) 句字幕")
                                        } else {
                                            Text("未关联文件").foregroundStyle(.red)
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    if queue.taskID == task.id, queue.mediaID == item.id {
                                        Text(queue.isCancelling ? "正在取消，等待当前操作结束" : queue.progressText ?? "处理中")
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
                                    if syncSettings.originalMediaState(for: item) != nil {
                                        Button("关联云端媒体", systemImage: "icloud.and.arrow.down") {
                                            associateCloudOriginal(for: item)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }

                                    if item.status.isRetryable {
                                        Button(item.status.isTranslationPaused ? "继续翻译" : "重试", systemImage: "arrow.clockwise") {
                                            if task.parameters.transcription.provider == .openAICompatible, !item.status.isTranslationPaused {
                                                pendingCloudRetryItem = item
                                            } else {
                                                do { try queue.start(taskID: task.id, mediaID: item.id) }
                                                catch { errorMessage = error.localizedDescription }
                                            }
                                        }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .disabled(queue.taskID != nil || task.items.isEmpty)
                                    }

                                    if queue.taskID == task.id, queue.isScheduled(mediaID: item.id) {
                                        Button("取消") {
                                            do { try queue.cancel(mediaID: item.id) }
                                            catch { errorMessage = error.localizedDescription }
                                        }
                                        .controlSize(.small)
                                        .disabled(queue.isCancelling && queue.mediaID == item.id)
                                    }

                                    Button("校对", systemImage: "chevron.right") {
                                        selectedMediaID = item.id
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption.bold())
                                    .foregroundStyle(.tint)
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)

                            // Inline Failure Diagnosis Drawer
                            if case .translationPaused(let reason) = item.status {
                                Label {
                                    Text("翻译暂停，成果已保存。\(reason) 可稍后继续翻译，或进入校对导出原文。")
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
                                    Text("失败原因：\(reason)")
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

    private func associateCloudOriginal(for item: TaskMediaItem) {
        Task {
            do {
                try await syncSettings.associateOriginal(for: item)
                TaskLibrary.shared.refresh()
                noticeMessage = "原媒体已成功下载并关联"
            } catch SharedDocumentError.downloadRequired {
                noticeMessage = "已请求系统下载原媒体，请稍候下载完成后再次关联"
            } catch {
                errorMessage = "关联原媒体失败：\(error.localizedDescription)"
            }
        }
    }
}

#endif
