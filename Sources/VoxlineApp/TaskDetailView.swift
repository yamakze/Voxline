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
            VStack(alignment: .leading, spacing: 18) {
                // Compact Metrics Bar
                compactMetricsBar

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
                            Text("每批最多 \(translation.batchSize) 条字幕").font(.caption2)
                            DisclosureGroup("系统提示词") {
                                Text(translation.systemPrompt).font(.caption2).textSelection(.enabled)
                            }
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
