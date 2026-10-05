#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore

struct IOSTaskLibraryView: View {
    @State private var library = IOSTaskLibrary.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var foregroundMessage: String?
    @State private var importing = false
    @State private var deletingTask: ProcessingTask?
    @State private var replacement: ProcessingTask?
    @State private var newTaskDraft: ProcessingTask?
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if library.tasks.isEmpty {
                    ContentUnavailableView {
                        Label("还没有任务", systemImage: "tray")
                    } description: {
                        Text("创建本地任务或导入 Mac 的 .voxline 成果。")
                    } actions: {
                        HStack(spacing: 12) {
                            Button {
                                newTaskDraft = ProcessingTask()
                            } label: {
                                Label("新建任务", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                importing = true
                            } label: {
                                Label("导入任务", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    List {
                        ForEach(library.tasks) { task in
                            NavigationLink(value: task.id) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(task.title).font(.headline)
                                    Text("\(task.items.count) 个媒体 · \(task.completedCount) 完成" + (task.failedCount > 0 ? " · \(task.failedCount) 失败" : ""))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Text(task.status.label).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                            .contextMenu {
                                Button("删除", systemImage: "trash", role: .destructive) { deletingTask = task }
                                    .disabled(library.queue.taskID == task.id)
                            }
                        }
                        .onMove { offsets, destination in
                            var tasks = library.tasks
                            tasks.move(fromOffsets: offsets, toOffset: destination)
                            let entries = tasks.compactMap { task in library.storage.entries.first { $0.taskID == task.id } }
                                + library.storage.entries.filter { $0.task == nil }
                            do { try library.storage.reorder(entryIDs: entries.map(\.id)) }
                            catch { library.errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle("任务")
            .navigationDestination(for: UUID.self) { taskID in
                IOSTaskDetailView(library: library, taskID: taskID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { IOSSettingsView() } label: { Label("设置", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newTaskDraft = ProcessingTask()
                    } label: {
                        Label("新建任务", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("导入任务", systemImage: "square.and.arrow.down") { importing = true }
                }
            }
            .sheet(item: $newTaskDraft) { draft in
                TaskConfigurationView(
                    task: Binding(
                        get: { newTaskDraft ?? draft },
                        set: { newTaskDraft = $0 }
                    ),
                    onCommit: { prepared in
                        try library.save(prepared)
                        library.load()
                        let newID = prepared.id
                        newTaskDraft = nil
                        navigationPath.append(newID)
                    }
                )
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
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background, library.queue.taskID != nil else { return }
                do {
                    try library.queue.cancel()
                    foregroundMessage = "应用已进入后台，处理停止调度。已提交成果保留，请返回任务详情继续未完成处理。"
                } catch { library.errorMessage = error.localizedDescription }
            }
            .alert("前台处理已停止", isPresented: Binding(
                get: { foregroundMessage != nil && scenePhase == .active },
                set: { if !$0 { foregroundMessage = nil } })) {
                Button("好") { foregroundMessage = nil }
            } message: { Text(foregroundMessage ?? "") }
            .onOpenURL { importTask($0) }
            .confirmationDialog("删除本地任务？", isPresented: Binding(
                get: { deletingTask != nil }, set: { if !$0 { deletingTask = nil } }), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    do {
                        if let deletingTask {
                            guard library.queue.taskID != deletingTask.id else { throw CheckpointError.workRunning }
                            try library.storage.delete(taskID: deletingTask.id)
                        }
                        deletingTask = nil
                    } catch { library.errorMessage = error.localizedDescription }
                }
                Button("取消", role: .cancel) { deletingTask = nil }
            } message: { Text("删除设备任务副本、字幕成果和不再被其他任务使用的媒体关联、音频缓存及转写证据。导入源文件和音视频保留；清理失败时任务保留，可重试删除。") }
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
    @State private var editingParameters = false
    @State private var configuringTask = false
    @State private var errorMessage: String?

    var body: some View {
        if let task = library.task(taskID) {
            List {
                // MARK: 1. 概览指标
                Section("概览") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            HStack(spacing: 4) {
                                Image(systemName: "film.stack").foregroundStyle(.secondary)
                                Text("\(task.items.count) 媒体").font(.subheadline.weight(.medium))
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("\(task.completedCount) 完成").font(.subheadline.weight(.medium))
                            }
                            if task.failedCount > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                    Text("\(task.failedCount) 失败").font(.subheadline.weight(.medium))
                                }
                            }
                            let totalCues = task.items.reduce(0) { $0 + $1.cues.count }
                            HStack(spacing: 4) {
                                Image(systemName: "character.bubble").foregroundStyle(.secondary)
                                Text("\(totalCues) 句字幕").font(.subheadline.weight(.medium))
                            }
                        }

                        if !task.items.isEmpty {
                            let progress = Double(task.completedCount) / Double(task.items.count)
                            HStack(spacing: 8) {
                                ProgressView(value: progress)
                                Text(String(format: "%.0f%%", progress * 100))
                                    .font(.caption.monospacedDigit().bold())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            Text("状态")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(task.status.label)
                                .font(.caption.bold())
                                .foregroundStyle(task.status == .completed ? .green : .primary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: 2. 处理控制
                if library.queue.taskID == taskID {
                    Section("处理控制") {
                        HStack {
                            if let fraction = library.queue.extractionFraction {
                                ProgressView(value: fraction).frame(width: 60)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.queue.isCancelling ? "正在取消，等待当前操作结束…" : (library.queue.progressText ?? "处理中…"))
                                    .font(.caption.weight(.medium))
                                if let wait = library.queue.translationRetryWait, !library.queue.isCancelling {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text(wait.label(at: context.date))
                                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Button("取消任务") {
                                do { try library.queue.cancel() }
                                catch { errorMessage = error.localizedDescription }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(library.queue.isCancelling)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section("处理控制") {
                        Button(task.startedAt == nil ? "开始处理" : "继续未完成处理", systemImage: "play.fill") {
                            do { try library.queue.start(taskID: taskID) }
                            catch { errorMessage = error.localizedDescription }
                        }
                        .disabled(library.queue.taskID != nil || !task.items.contains(where: \.canResumeProcessing))
                        Text("请保持应用在前台；离开后若系统中断，重新打开可继续已保存的检查点。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = library.queue.errorMessage {
                    Section("处理未完成") { Text(error).font(.caption).foregroundStyle(.red) }
                }

                // MARK: 3. 当前参数
                Section("当前参数") {
                    LabeledContent("转写模型", value: task.parameters.transcription.modelID)
                    LabeledContent("原文语言", value: task.parameters.transcription.languageMode == .automatic ? "自动识别" : (task.parameters.transcription.languageCode ?? "未知"))

                    if let settings = task.parameters.translation {
                        LabeledContent("目标语言", value: settings.targetLanguage)
                        LabeledContent("每批字幕数", value: String(settings.batchSize))
                        switch settings.engine {
                        case .openAICompatible(let api):
                            LabeledContent("翻译引擎", value: "OpenAI 兼容接口")
                            LabeledContent("模型", value: api.modelID)
                            NavigationLink("配置本机翻译服务") {
                                TranslationServicesSettingsView(referencedSettings: settings, onBindService: { service in
                                    try library.bindTranslationService(service, taskID: taskID)
                                })
                            }
                        case .appleTranslation(let source):
                            LabeledContent("翻译引擎", value: "Apple 本机翻译")
                            LabeledContent("源语言", value: source)
                            NavigationLink("准备本机语言") {
                                IOSAppleLanguagesView(settings: settings)
                            }
                        }
                    } else {
                        LabeledContent("字幕翻译", value: "未启用")
                    }

                    let outputsText = task.parameters.srtOutputs.map(\.label).joined(separator: "、")
                    LabeledContent("导出选项", value: outputsText.isEmpty ? "无" : outputsText)

                    HStack {
                        Spacer()
                        if task.startedAt == nil {
                            Button("任务准备与媒体…") { configuringTask = true }
                                .disabled(library.queue.taskID == taskID)
                        }
                        Button("调整参数…") { editingParameters = true }
                            .disabled(library.queue.taskID == taskID)
                    }
                    .font(.subheadline)
                }

                // MARK: 4. 媒体列表
                Section("媒体列表 (\(task.items.count))") {
                    if task.items.isEmpty {
                        ContentUnavailableView("暂无媒体条目", systemImage: "film.stack", description: Text("请点击任务准备添加音视频。"))
                    } else {
                        ForEach(task.items) { item in
                            NavigationLink {
                                IOSMediaDetailView(library: library, taskID: taskID, mediaID: item.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: item.kind == .video ? "film" : "waveform")
                                            .font(.title3)
                                            .foregroundStyle(item.kind == .video ? .blue : .purple)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title)
                                                .font(.headline)
                                                .lineLimit(1)

                                            HStack(spacing: 8) {
                                                if let media = item.media {
                                                    Text(String(format: "%.1fs", Double(media.durationMilliseconds) / 1000.0))
                                                    Text("音轨 \(media.audioTrackID)")
                                                    Text("\(item.cues.count) 句字幕")
                                                } else {
                                                    Text("未关联媒体").foregroundStyle(.red)
                                                }
                                            }
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Text(item.status.label)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.12), in: .capsule)
                                    }

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        MediaProcessingStepsView(item: item, hasTranslation: task.parameters.translation != nil)
                                            .padding(.vertical, 2)
                                    }

                                    if case .translationPaused(let reason) = item.status {
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                                            Text("翻译暂停，成果已保存。\(reason) 可进入校对导出原文或继续翻译。")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                        .padding(6)
                                        .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 6))
                                    }

                                    if case .failed(let reason) = item.status {
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                                            Text("失败原因：\(reason)")
                                                .font(.caption2)
                                                .foregroundStyle(.red)
                                        }
                                        .padding(6)
                                        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 6))
                                    }

                                }
                                .padding(.vertical, 4)
                            }
                            .contextMenu {
                                if item.status.isRetryable && item.canResumeProcessing {
                                    Button(item.status.isTranslationPaused ? "继续翻译" : "重试", systemImage: "arrow.clockwise") {
                                        do { try library.queue.start(taskID: task.id, mediaID: item.id) }
                                        catch { errorMessage = error.localizedDescription }
                                    }
                                    .disabled(library.queue.taskID != nil)
                                }
                                if library.queue.taskID == task.id, library.queue.isScheduled(mediaID: item.id) {
                                    Button("取消此媒体", systemImage: "stop.circle") {
                                        do { try library.queue.cancel(mediaID: item.id) }
                                        catch { errorMessage = error.localizedDescription }
                                    }
                                    .disabled(library.queue.isCancelling && library.queue.mediaID == item.id)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("调整参数", systemImage: "slider.horizontal.3") { editingParameters = true }
                        .disabled(library.queue.taskID == taskID)
                }
            }
            .sheet(isPresented: $editingParameters) {
                TaskTranslationParametersView(task: task) { updated, original in
                    guard library.task(taskID) == original else { throw TaskValidationError.taskChanged }
                    try library.save(updated)
                }
            }
            .sheet(isPresented: $configuringTask) {
                TaskConfigurationView(
                    task: Binding(
                        get: { library.task(taskID) ?? task },
                        set: { _ in }
                    ),
                    onCommit: { updated in
                        try library.save(updated)
                        library.load()
                    }
                )
            }
            .alert("操作未完成", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        } else { ContentUnavailableView("任务不存在", systemImage: "tray") }
    }
}

#endif
