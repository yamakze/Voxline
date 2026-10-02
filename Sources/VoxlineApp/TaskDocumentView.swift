import SwiftUI
import VoxlineCore

struct TaskDocumentView: View {
    @Binding var document: VoxlineDocument
    let fileURL: URL?
    @State private var selectedMediaID: UUID?
    @State private var isConfiguring = false
    @State private var preparationShown = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedMediaID) {
                Button("任务概览", systemImage: "rectangle.stack") { selectedMediaID = nil }
                ForEach(document.task.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(item.title, systemImage: item.kind == .video ? "film" : "waveform")
                        Text(item.status.label).font(.caption).foregroundStyle(.secondary)
                    }.tag(item.id)
                }
            }
            .navigationTitle("Voxline")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            .safeAreaInset(edge: .bottom) {
                Button("任务列表", systemImage: "tray.full") { openWindow(id: "tasks") }
                    .frame(maxWidth: .infinity).padding(12)
            }
        } detail: {
            Group {
                if let index = document.task.items.firstIndex(where: { $0.id == selectedMediaID }) {
                    MediaItemView(item: $document.task.items[index]).id(document.task.items[index].id)
                } else {
                    TaskOverviewView(task: $document.task, isConfiguring: $isConfiguring, selectedMediaID: $selectedMediaID)
                }
            }
            .navigationTitle(document.task.title)
            .toolbar {
                Button("任务准备", systemImage: "slider.horizontal.3") { isConfiguring = true }
                    .disabled(document.task.startedAt != nil)
                    .help(document.task.startedAt == nil ? "添加视频与选择本次参数" : "本次参数已固定")
            }
        }
        .frame(minWidth: 1060, minHeight: 640)
        .sheet(isPresented: $isConfiguring) { TaskConfigurationView(task: $document.task) }
        .onAppear {
            if !preparationShown, document.task.items.isEmpty {
                preparationShown = true
                isConfiguring = true
            }
        }
        .onChange(of: document.task, initial: true) { _, task in TaskLibrary.shared.register(task, at: fileURL) }
        .onChange(of: fileURL) { _, url in TaskLibrary.shared.register(document.task, at: url) }
        .onDisappear { TaskLibrary.shared.removeOpenTask(document.task.id) }
    }
}

extension TaskMediaStatus {
    var isFailure: Bool { if case .failed = self { true } else { false } }
    var isRetryable: Bool {
        switch self { case .failed, .interrupted, .cancelled: true; default: false }
    }
    var label: String {
        switch self {
        case .pending: "待处理"
        case .needsReview: "已有成果，待确认"
        case .running(let stage): stage.label
        case .completed: "已完成"
        case .failed(let reason): "失败：\(reason)"
        case .cancelled: "已取消"
        case .interrupted(let stage): "已中断：\(stage.label)"
        }
    }
}

extension SRTOutputKind {
    var label: String {
        switch self { case .source: "原文"; case .translation: "译文"; case .bilingual: "双语" }
    }
}

extension ProcessingStage {
    var label: String {
        switch self {
        case .audioExtraction: "提取音频"
        case .transcription: "转写"
        case .translation: "翻译"
        }
    }
}

extension ProcessingTaskStatus {
    var label: String {
        switch self {
        case .draft: "未开始"
        case .queued: "待处理"
        case .needsReview: "旧成果待确认"
        case .running: "处理中"
        case .interrupted: "已中断，待恢复"
        case .completed: "全部完成"
        case .partiallyFailed: "部分失败"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}
