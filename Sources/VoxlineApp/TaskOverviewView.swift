import SwiftUI
import VoxlineCore

struct TaskOverviewView: View {
    @Binding var task: ProcessingTask
    @Binding var isConfiguring: Bool
    @Binding var selectedMediaID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("任务名称", text: $task.title).font(.largeTitle.bold()).textFieldStyle(.plain)
                    Text(task.status.label).foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    Label("\(task.items.count) 个媒体", systemImage: "film.stack")
                    Label("\(task.completedCount) 完成", systemImage: "checkmark.circle")
                    Label("\(task.failedCount) 失败", systemImage: "exclamationmark.circle")
                    Spacer()
                    if task.startedAt == nil { Button("添加媒体与参数", systemImage: "plus") { isConfiguring = true } }
                }.padding(16).modifier(NativeControlSurface())
                if !task.items.isEmpty {
                    ProgressView(value: Double(task.completedCount), total: Double(task.items.count)) {
                        Text("完成媒体 \(task.completedCount) / \(task.items.count)")
                    }
                }
                Label("处理队列尚未接通。当前可准备和保存任务、关联视频、浏览已有字幕。", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("本次参数").font(.headline)
                            Spacer()
                            Text(task.startedAt == nil ? "开始前可修改" : "已固定").font(.caption).foregroundStyle(.secondary)
                        }
                        LabeledContent("转写模型", value: task.parameters.transcription.modelID)
                        LabeledContent("原文语言", value: task.parameters.transcription.languageCode ?? "自动识别")
                        if let translation = task.parameters.translation {
                            LabeledContent("翻译地址", value: translation.baseURL.absoluteString)
                            LabeledContent("翻译模型", value: translation.modelID)
                            LabeledContent("目标语言", value: translation.targetLanguage)
                            if translation.serviceID == nil {
                                Text("尚未关联本地翻译服务；仅保存参数，不能启动翻译。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else { LabeledContent("翻译", value: "关闭") }
                        LabeledContent("SRT 输出", value: task.parameters.srtOutputs.map(\.label).joined(separator: "、"))
                    }.padding(8).textSelection(.enabled)
                }
                if task.items.isEmpty {
                    ContentUnavailableView("添加本次任务的媒体", systemImage: "film.stack",
                                           description: Text("在任务准备中多选本地视频，并确认音轨和参数。"))
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("处理顺序").font(.headline).padding(.bottom, 12)
                        ForEach(Array(task.items.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .top, spacing: 16) {
                                Text("\(index + 1)").font(.headline).foregroundStyle(.secondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(item.title, systemImage: item.kind == .video ? "film" : "waveform").font(.headline)
                                    Text(item.status.label).foregroundStyle(item.status.isFailure ? Color.red : Color.secondary)
                                    if let media = item.media {
                                        Text(String(format: "%.1f 秒 · 音轨 %d · %d 条字幕", Double(media.durationMilliseconds) / 1000,
                                                    media.audioTrackID, item.cues.count)).font(.caption).foregroundStyle(.secondary)
                                    } else { Text("尚未关联媒体").font(.caption).foregroundStyle(.secondary) }
                                    if item.status == .cancelled {
                                        Text("此记录未保存取消原因。").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if item.status.isRetryable {
                                    Text("重试待接通").font(.caption).foregroundStyle(.secondary)
                                }
                                Button(item.cues.isEmpty ? "媒体详情" : "查看字幕") { selectedMediaID = item.id }
                            }.padding(.vertical, 16)
                            Divider()
                        }
                    }
                }
            }.padding(28)
        }
    }
}
