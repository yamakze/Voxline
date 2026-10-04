#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore

struct IOSTaskLibraryView: View {
    @State private var library = IOSTaskLibrary()
    @State private var importing = false
    @State private var replacement: ProcessingTask?

    var body: some View {
        NavigationStack {
            Group {
                if library.tasks.isEmpty {
                    ContentUnavailableView {
                        Label("还没有任务", systemImage: "tray")
                    } description: {
                        Text("导入 Mac 的 .voxline 任务成果，再关联本地音视频进行播放校对。")
                    } actions: {
                        Button("导入任务", systemImage: "square.and.arrow.down") { importing = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(library.tasks) { task in
                        NavigationLink {
                            IOSTaskDetailView(library: library, taskID: task.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title).font(.headline)
                                Text("\(task.items.count) 个媒体 · \(task.completedCount) 完成 · \(task.failedCount) 失败")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text(task.status.label).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("任务")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("导入任务", systemImage: "square.and.arrow.down") { importing = true }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { IOSSettingsView() } label: { Label("设置", systemImage: "gearshape") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.voxlineTask, .json]) { result in
                switch result {
                case .success(let url): importTask(url)
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            .alert("任务读取失败", isPresented: Binding(
                get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button("好") { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "")
            }
            .task { library.load() }
            .onOpenURL { importTask($0) }
            .alert("替换本地任务？", isPresented: Binding(
                get: { replacement != nil }, set: { if !$0 { replacement = nil } })) {
                Button("取消", role: .cancel) { replacement = nil }
                Button("替换", role: .destructive) {
                    do {
                        if let replacement { try library.save(replacement) }
                        replacement = nil
                    } catch { library.errorMessage = error.localizedDescription }
                }
            } message: { Text("同 ID 任务已存在。替换会覆盖设备上的字幕校对，请确认已保留所需成果。") }
        }
    }

    private func importTask(_ url: URL) {
        do {
            let task = try library.readImportedTask(from: url)
            if library.task(task.id) != nil { replacement = task }
            else { try library.save(task) }
        } catch { library.errorMessage = error.localizedDescription }
    }

}

private struct IOSTaskDetailView: View {
    let library: IOSTaskLibrary
    let taskID: UUID

    var body: some View {
        if let task = library.task(taskID) {
            List {
                Section("任务") {
                    LabeledContent("状态", value: task.status.label)
                    LabeledContent("媒体", value: "\(task.items.count) 个")
                    LabeledContent("转写模型", value: task.parameters.transcription.modelID)
                }
                if let settings = task.parameters.translation {
                    Section("本次翻译") {
                        LabeledContent("目标语言", value: settings.targetLanguage)
                        LabeledContent("每批字幕数量", value: String(settings.batchSize))
                        switch settings.engine {
                        case .openAICompatible(let api):
                            LabeledContent("引擎", value: "OpenAI 兼容接口")
                            LabeledContent("模型", value: api.modelID)
                            Text(api.baseURL.absoluteString).font(.caption).textSelection(.enabled)
                            NavigationLink("本机翻译服务") { TranslationServicesSettingsView(referencedSettings: settings) }
                        case .appleTranslation(let source):
                            LabeledContent("引擎", value: "Apple 本机翻译")
                            LabeledContent("原文语言", value: source)
                            NavigationLink("准备本机语言") { IOSAppleLanguagesView(settings: settings) }
                        }
                        Text("参数来自任务快照；修改服务默认值不改变本次任务。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("媒体") {
                    ForEach(task.items) { item in
                        NavigationLink {
                            IOSMediaDetailView(library: library, taskID: taskID, mediaID: item.id)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title)
                                    Text(item.status.label).font(.caption).foregroundStyle(.secondary)
                                    Text("\(item.cues.count) 条字幕").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: item.kind == .audio ? "waveform" : "film")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
        } else { ContentUnavailableView("任务不存在", systemImage: "tray") }
    }
}

#endif
