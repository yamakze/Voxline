import SwiftUI
import VoxlineCore

public struct TaskDetailView: View {
    @Binding var task: ProcessingTask
    @Binding var isConfiguring: Bool
    @Binding var selectedMediaID: UUID?

    @State private var queue = TaskProcessingQueue.shared
    @State private var errorMessage: String?

    public init(task: Binding<ProcessingTask>, isConfiguring: Binding<Bool>, selectedMediaID: Binding<UUID?>) {
        _task = task
        _isConfiguring = isConfiguring
        _selectedMediaID = selectedMediaID
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Xcode Organizer Summary Card
                xcodeOrganizerSummaryCard

                // Parameter Snapshot (Read-only, clean disclosure)
                parametersSnapshotCard

                // Xcode Build Tasks Pipeline Queue
                xcodeBuildTasksQueue
            }
            .padding(24)
            if let reason = ProcessingAvailability.reason(for: task) {
                Text(reason).font(.callout).foregroundStyle(.secondary).padding()
            }
            if let error = queue.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding()
            }
        }
        .alert("处理未开始或取消失败", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - Xcode Organizer Summary Card
    private var xcodeOrganizerSummaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 2) {
                        if task.startedAt == nil {
                            TextField("任务名称", text: $task.title)
                                .font(.title2.bold())
                                .textFieldStyle(.plain)
                        } else {
                            Text(task.title)
                                .font(.title2.bold())
                        }

                        HStack(spacing: 8) {
                            TaskStatusBadge(status: task.status)
                            if let started = task.startedAt {
                                Text("开始于 \(started.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Spacer()

                // Xcode Scheme Actions Bar
                HStack(spacing: 10) {
                    if task.startedAt == nil {
                        Button("调整参数与媒体", systemImage: "slider.horizontal.3") {
                            isConfiguring = true
                        }
                        .buttonStyle(.bordered)
                    }
                    if queue.taskID == task.id {
                        Button(queue.isCancelling ? "正在取消…" : "取消任务", systemImage: "stop.fill") {
                            do { try queue.cancel() }
                            catch { errorMessage = error.localizedDescription }
                        }
                        .buttonStyle(.bordered).disabled(queue.isCancelling)
                    } else {
                        Button(task.startedAt == nil ? "开始顺序处理" : "继续未完成项", systemImage: "play.fill") {
                            do { try queue.start(taskID: task.id) }
                            catch { errorMessage = error.localizedDescription }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(queue.taskID != nil || ProcessingAvailability.reason(for: task) != nil || task.status == .completed)
                    }
                }
            }

            Divider()

            // Organizer Metrics Grid
            HStack(spacing: 28) {
                metricItem(title: "媒体总数", value: "\(task.items.count)", icon: "film.stack", color: .blue)
                metricItem(title: "已完成", value: "\(task.completedCount)", icon: "checkmark.circle.fill", color: .green)
                if task.failedCount > 0 {
                    metricItem(title: "失败项", value: "\(task.failedCount)", icon: "xmark.circle.fill", color: .red)
                }
                let totalCues = task.items.reduce(0) { $0 + $1.cues.count }
                metricItem(title: "生成字幕句数", value: "\(totalCues)", icon: "captions.bubble", color: .purple)
                Spacer()

                // Circular / Percent indicator
                if !task.items.isEmpty {
                    let progress = Double(task.completedCount) / Double(task.items.count)
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .frame(width: 120)
                        Text(String(format: "%.0f%%", progress * 100))
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .liquidGlassSurface()
    }

    private func metricItem(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Parameter Snapshot
    private var parametersSnapshotCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 32) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("转写引擎").font(.caption2.bold()).foregroundStyle(.secondary)
                        Text(task.parameters.transcription.modelID).font(.caption.monospaced())
                        Text("语言：\(task.parameters.transcription.languageCode ?? "自动识别")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("字幕翻译").font(.caption2.bold()).foregroundStyle(.secondary)
                        if let translation = task.parameters.translation {
                            Text("\(translation.modelID) (\(translation.targetLanguage))")
                                .font(.caption.bold())
                            Text(translation.baseURL.absoluteString)
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("未启用翻译").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("SRT 导出计划").font(.caption2.bold()).foregroundStyle(.secondary)
                        Text(task.parameters.srtOutputs.map(\.label).joined(separator: " · "))
                            .font(.caption)
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            HStack {
                Label("本次参数快照 (只读)", systemImage: "slider.horizontal.2")
                    .font(.subheadline.bold())
                Spacer()
                Text(task.startedAt == nil ? "开始前可修改" : "处理中已锁定")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .liquidGlassSurface()
    }

    // MARK: - Xcode Build Tasks Pipeline Queue
    private var xcodeBuildTasksQueue: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("批处理流水线清单", systemImage: "list.bullet.rectangle.portrait")
                    .font(.headline)
                Spacer()
                Text("按序执行 · 单项失败不阻断其余")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                                        if let fraction = queue.extractionFraction {
                                            ProgressView(value: fraction).frame(width: 180)
                                        }
                                    }
                                }

                                Spacer()

                                // Xcode Step Pipeline Badge (Audio -> Transcription -> Translation -> Ready)
                                XcodeStepPipelineView(
                                    item: item,
                                    hasTranslation: task.parameters.translation != nil
                                )

                                // In-line Action Buttons
                                HStack(spacing: 6) {
                                    if item.status.isRetryable {
                                        Button("重试", systemImage: "arrow.clockwise") {
                                            do { try queue.start(taskID: task.id, mediaID: item.id) }
                                            catch { errorMessage = error.localizedDescription }
                                        }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .disabled(queue.taskID != nil || ProcessingAvailability.reason(for: task) != nil)
                                    }

                                    if queue.taskID == task.id,
                                       item.status == .pending || queue.mediaID == item.id {
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
}
