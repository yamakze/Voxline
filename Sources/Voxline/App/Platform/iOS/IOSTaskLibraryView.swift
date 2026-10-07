#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineWorkflow

struct IOSTaskLibraryView: View {
    @State private var library = IOSTaskLibrary.shared
    @State private var syncSettings = TaskSyncSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var deletingTask: ProcessingTask?
    @State private var replacement: ProcessingTask?
    @State private var newTaskDraft: ProcessingTask?
    @State private var navigationPath = NavigationPath()
    @State private var sharingURL: URL?
    @State private var conflictResolutionTaskID: UUID?
    @State private var noticeMessage: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if library.storage.entries.isEmpty {
                    emptyStateView
                } else {
                    taskList
                }
            }
            .navigationTitle("任务")
            .navigationDestination(for: UUID.self) { taskID in
                IOSTaskDetailView(library: library, taskID: taskID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        IOSSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button {
                            newTaskDraft = ProcessingTask()
                        } label: {
                            Label("新建任务", systemImage: "plus")
                        }

                        Button {
                            importing = true
                        } label: {
                            Label("导入任务文件…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.voxlineAccent)
                    }
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
            .sheet(item: Binding(get: { sharingURL.map { SharePayload(url: $0) } }, set: { sharingURL = $0?.url })) { payload in
                ShareActivitySheet(activityItems: [payload.url])
            }
            .sheet(isPresented: Binding(
                get: { conflictResolutionTaskID != nil },
                set: { if !$0 { conflictResolutionTaskID = nil } }
            )) {
                if let taskID = conflictResolutionTaskID {
                    TaskConflictResolutionSheet(taskID: taskID) {
                        library.load()
                        syncSettings.refresh()
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.voxlineTask, .json]) { result in
                switch result {
                case .success(let url): importTask(url)
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            .alert("读取失败", isPresented: Binding(
                get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button("好") { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "")
            }
            .alert("提示", isPresented: Binding(
                get: { noticeMessage != nil }, set: { if !$0 { noticeMessage = nil } })) {
                Button("好") { noticeMessage = nil }
            } message: {
                Text(noticeMessage ?? "")
            }
            .task { library.load() }
            .onChange(of: scenePhase) { _, phase in
                library.handleScenePhaseChange(to: phase)
            }
            .onOpenURL { importTask($0) }
            .confirmationDialog("删除任务？", isPresented: Binding(
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
            } message: {
                Text("将删除设备上的任务及其字幕，源媒体文件不受影响。")
            }
            .alert("覆盖同名任务？", isPresented: Binding(
                get: { replacement != nil }, set: { if !$0 { replacement = nil } })) {
                Button("取消", role: .cancel) { replacement = nil }
                Button("覆盖", role: .destructive) {
                    do {
                        if let replacement { try library.save(replacement) }
                        replacement = nil
                    } catch { library.errorMessage = error.localizedDescription }
                }
            } message: {
                Text("已存在同 ID 任务，覆盖将替换已有校对成果。")
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("暂无任务", systemImage: "waveform.badge.magnifyingglass")
        } description: {
            Text("添加音视频开始本地或云端转写与翻译")
        } actions: {
            HStack(spacing: 14) {
                Button {
                    newTaskDraft = ProcessingTask()
                } label: {
                    Label("新建任务", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    importing = true
                } label: {
                    Label("导入任务", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 4)
        }
    }

    private var taskList: some View {
        List {
            ForEach(library.storage.entries) { entry in
                let fileState = entry.url.flatMap { syncSettings.fileStates[$0.standardizedFileURL] }
                let isPlaceholder = entry.task == nil || fileState == .notDownloaded

                if let task = entry.task, !isPlaceholder {
                    NavigationLink(value: task.id) {
                        taskCard(task, entry: entry, fileState: fileState)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deletingTask = task
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .disabled(library.queue.taskID == task.id)

                        Button {
                            shareTask(task)
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)

                        if fileState == .conflict {
                            Button {
                                conflictResolutionTaskID = task.id
                            } label: {
                                Label("解决冲突", systemImage: "exclamationmark.triangle")
                            }
                            .tint(.orange)
                        }
                    }
                    .contextMenu {
                        if fileState == .conflict {
                            Button {
                                conflictResolutionTaskID = task.id
                            } label: {
                                Label("解决版本冲突…", systemImage: "exclamationmark.triangle")
                            }
                            Divider()
                        }

                        Button {
                            shareTask(task)
                        } label: {
                            Label("分享任务文件 (.voxline)", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            deletingTask = task
                        } label: {
                            Label("删除任务", systemImage: "trash")
                        }
                        .disabled(library.queue.taskID == task.id)
                    }
                } else {
                    placeholderEntryRow(entry: entry, fileState: fileState)
                        .contextMenu {
                            if fileState == .conflict {
                                Button {
                                    conflictResolutionTaskID = entry.taskID
                                } label: {
                                    Label("解决版本冲突…", systemImage: "exclamationmark.triangle")
                                }
                                Divider()
                            }
                            if let url = entry.url {
                                Button {
                                    downloadPlaceholder(url: url)
                                } label: {
                                    Label("从云端下载", systemImage: "arrow.down.circle")
                                }
                            }
                        }
                }
            }
            .onMove { source, destination in
                do {
                    try library.moveTasks(fromOffsets: source, toOffset: destination)
                } catch {
                    library.errorMessage = error.localizedDescription
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func placeholderEntryRow(entry: TaskLibrary.Entry, fileState: TaskSyncSettings.FileState?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let fileState {
                        SyncFileStatusBadge(state: fileState)
                    }
                }

                Text("云端任务尚未下载完整内容与字幕。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let problem = entry.error {
                    Text(problem)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            if fileState == .conflict {
                Button("解决冲突") {
                    conflictResolutionTaskID = entry.taskID
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if let url = entry.url {
                Button("下载", systemImage: "arrow.down.circle") {
                    downloadPlaceholder(url: url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func downloadPlaceholder(url: URL) {
        do {
            try syncSettings.requestDownload(url)
            library.load()
            syncSettings.refresh()
            noticeMessage = "已请求系统下载云端任务，请稍候。"
        } catch {
            library.errorMessage = "请求下载失败：\(error.localizedDescription)"
        }
    }

    private func taskCard(_ task: ProcessingTask, entry: TaskLibrary.Entry, fileState: TaskSyncSettings.FileState?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let fileState {
                    SyncFileStatusBadge(state: fileState)
                }
                statusBadge(task.status)
            }

            if fileState == .conflict {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("存在云端冲突版本")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 8) {
                Text("\(task.items.count) 个媒体")
                Text("•")
                Text("\(task.completedCount) 完成")
                if task.failedCount > 0 {
                    Text("•")
                    Text("\(task.failedCount) 失败")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !task.items.isEmpty {
                let progress = Double(task.completedCount) / Double(task.items.count)
                ProgressView(value: progress)
                    .tint(task.status == .completed ? .green : Color.voxlineAccent)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(_ status: ProcessingTaskStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .completed:
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("已完成").foregroundStyle(.green)
            case .running:
                ProgressView().controlSize(.mini)
                Text("处理中").foregroundStyle(Color.voxlineAccent)
            case .queued:
                Circle().fill(Color.blue).frame(width: 6, height: 6)
                Text("排队中").foregroundStyle(.blue)
            case .draft:
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                Text("草稿").foregroundStyle(.secondary)
            case .cancelled:
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("已取消").foregroundStyle(.orange)
            case .interrupted, .translationPaused:
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("已暂停").foregroundStyle(.orange)
            case .needsReview:
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("待校对").foregroundStyle(.orange)
            case .partiallyFailed, .failed:
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("失败").foregroundStyle(.red)
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    private func importTask(_ url: URL) {
        do {
            let task = try library.readImportedTask(from: url)
            if library.task(task.id) != nil { replacement = task }
            else { try library.save(task) }
        } catch { library.errorMessage = error.localizedDescription }
    }

    private func shareTask(_ task: ProcessingTask) {
        do {
            let url = try IOSExportHelper.prepareTaskArchive(for: task)
            sharingURL = url
        } catch {
            library.errorMessage = error.localizedDescription
        }
    }
}

private struct IOSTaskDetailView: View {
    let library: IOSTaskLibrary
    let taskID: UUID
    @State private var syncSettings = TaskSyncSettings.shared
    @State private var editingParameters = false
    @State private var configuringTask = false
    @State private var showConflictSheet = false
    @State private var pendingCloudStartConfirmation = false
    @State private var pendingCloudRetryItem: TaskMediaItem?
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var sharingURL: URL?

    private var fileState: TaskSyncSettings.FileState? {
        library.storage.url(for: taskID).flatMap { syncSettings.fileStates[$0.standardizedFileURL] }
    }

    var body: some View {
        if let task = library.task(taskID) {
            List {
                if fileState == .conflict {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("存在云端冲突版本")
                                    .font(.subheadline.bold())
                                Text("另一设备在离线期间保存了不同版本。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("解决冲突…") {
                                showConflictSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                // 顶部指标与控制卡片
                Section {
                    overviewCard(task)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                // 媒体条目列表
                Section("媒体条目 (\(task.items.count))") {
                    if task.items.isEmpty {
                        ContentUnavailableView("暂无媒体条目", systemImage: "film.stack",
                                               description: Text("请点击右上角参数菜单添加音视频。"))
                    } else {
                        ForEach(task.items) { item in
                            NavigationLink {
                                IOSMediaDetailView(library: library, taskID: taskID, mediaID: item.id)
                            } label: {
                                mediaItemCard(item: item, task: task)
                            }
                            .contextMenu {
                                if syncSettings.originalMediaState(for: item) != nil {
                                    Button {
                                        associateCloudOriginal(for: item)
                                    } label: {
                                        Label("从云端下载并关联媒体", systemImage: "icloud.and.arrow.down")
                                    }
                                }
                                if item.status.isRetryable && item.canResumeProcessing {
                                    Button(item.status.isTranslationPaused ? "继续翻译" : "重试", systemImage: "arrow.clockwise") {
                                        handleRetryItem(item: item, in: task)
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
            .listStyle(.insetGrouped)
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            shareTask(task)
                        } label: {
                            Label("分享任务文件 (.voxline)", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        if task.startedAt == nil {
                            Button {
                                configuringTask = true
                            } label: {
                                Label("媒体管理与准备…", systemImage: "film")
                            }
                            .disabled(library.queue.taskID == taskID)
                        }

                        Button {
                            editingParameters = true
                        } label: {
                            Label("调整参数…", systemImage: "slider.horizontal.3")
                        }
                        .disabled(library.queue.taskID == taskID)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: Binding(get: { sharingURL.map { SharePayload(url: $0) } }, set: { sharingURL = $0?.url })) { payload in
                ShareActivitySheet(activityItems: [payload.url])
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
            .sheet(isPresented: $showConflictSheet) {
                TaskConflictResolutionSheet(taskID: taskID, draftTask: task) {
                    library.load()
                    syncSettings.refresh()
                }
            }
            .confirmationDialog("确认开始云端转写？", isPresented: $pendingCloudStartConfirmation, titleVisibility: .visible) {
                Button("确认并开始") {
                    do { try library.queue.start(taskID: taskID) }
                    catch { errorMessage = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            } message: {
                let transcription = task.parameters.transcription
                let destination = transcription.cloud?.baseURL.absoluteString ?? "未配置服务"
                let lang = transcription.languageMode == .specified ? (transcription.languageCode ?? "指定语言") : "自动识别"
                Text("服务：\(destination)\n模型：\(transcription.modelID) · 语言：\(lang)\n将提取音轨并上传至该服务进行云端转写。")
            }
            .confirmationDialog("确认开始云端转写？", isPresented: Binding(
                get: { pendingCloudRetryItem != nil },
                set: { if !$0 { pendingCloudRetryItem = nil } }
            ), titleVisibility: .visible) {
                Button("确认并重试") {
                    if let item = pendingCloudRetryItem {
                        pendingCloudRetryItem = nil
                        do { try library.queue.start(taskID: task.id, mediaID: item.id) }
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
            .alert("操作异常", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .alert("提示", isPresented: Binding(
                get: { noticeMessage != nil }, set: { if !$0 { noticeMessage = nil } })) {
                Button("好") { noticeMessage = nil }
            } message: { Text(noticeMessage ?? "") }
        } else {
            ContentUnavailableView("任务不存在", systemImage: "tray")
        }
    }

    // MARK: - 概览与控制卡片
    private func overviewCard(_ task: ProcessingTask) -> some View {
        VStack(spacing: 14) {
            // 参数概览条
            let transcription = task.parameters.transcription
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: transcription.provider == .openAICompatible ? "waveform.badge.mic" : "cpu")
                        .foregroundStyle(.secondary)
                    if transcription.provider == .openAICompatible {
                        Text("云端：\(transcription.modelID)")
                    } else {
                        Text("本地：\(transcription.modelID)")
                    }
                }
                Text("•").foregroundStyle(.secondary)
                Text(transcription.languageMode == .specified ? (transcription.languageCode ?? "指定") : "自动识别")
                if let translation = task.parameters.translation {
                    Text("•").foregroundStyle(.secondary)
                    Text("译：\(translation.targetLanguage)")
                }
                if let fileState {
                    Spacer()
                    SyncFileStatusBadge(state: fileState)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            // 指标行
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(task.items.count)")
                        .font(.title2.bold())
                    Text("媒体总数")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(task.completedCount)")
                        .font(.title2.bold())
                        .foregroundStyle(.green)
                    Text("已完成")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if task.failedCount > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(task.failedCount)")
                            .font(.title2.bold())
                            .foregroundStyle(.red)
                        Text("失败项")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                let totalCues = task.items.reduce(0) { $0 + $1.cues.count }
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(totalCues)")
                        .font(.title2.bold())
                    Text("字幕总句")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // 处理控制按钮或正在运行指示
            if library.queue.taskID == taskID {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(library.queue.isCancelling ? "正在取消…" : (library.queue.progressText ?? "处理中…"))
                            .font(.subheadline.weight(.medium))
                        if let wait = library.queue.translationRetryWait, !library.queue.isCancelling {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(wait.label(at: context.date))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Button("取消") {
                        do { try library.queue.cancel() }
                        catch { errorMessage = error.localizedDescription }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(library.queue.isCancelling)
                }
                .padding(10)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                let canResume = task.items.contains(where: \.canResumeProcessing)
                Button {
                    handleStartTask(task: task)
                } label: {
                    HStack {
                        Spacer()
                        Label(task.startedAt == nil ? "开始处理任务" : "继续未完成处理",
                              systemImage: task.startedAt == nil ? "play.fill" : "arrow.clockwise")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(library.queue.taskID != nil || !canResume)
            }

            if let error = library.queue.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 14)
    }

    // MARK: - 媒体卡片
    private func mediaItemCard(item: TaskMediaItem, task: ProcessingTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: item.kind == .video ? "film" : "waveform")
                    .font(.title3)
                    .foregroundStyle(item.kind == .video ? .blue : .purple)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if let media = item.media {
                            Text(String(format: "%.1fs", Double(media.durationMilliseconds) / 1000.0))
                            Text("•")
                            Text("音轨 \(media.audioTrackID)")
                            Text("•")
                            Text("\(item.cues.count) 句")
                        } else {
                            Text("未关联媒体")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if syncSettings.originalMediaState(for: item) != nil {
                    Button {
                        associateCloudOriginal(for: item)
                    } label: {
                        Label("关联媒体", systemImage: "icloud.and.arrow.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                itemStatusTag(item.status)
            }

            // 处理步骤进度指示
            ScrollView(.horizontal, showsIndicators: false) {
                MediaProcessingStepsView(
                    item: item,
                    hasTranslation: task.parameters.translation != nil,
                    provider: task.parameters.transcription.provider
                )
                .padding(.vertical, 2)
            }

            // 失败或暂停行快捷重试
            if case .translationPaused(let reason) = item.status {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                    Text("翻译暂停：\(reason)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer()
                    if item.status.isRetryable && item.canResumeProcessing {
                        Button("继续") {
                            handleRetryItem(item: item, in: task)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(library.queue.taskID != nil)
                    }
                }
            }

            if case .failed(let reason) = item.status {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    Spacer()
                    if item.status.isRetryable && item.canResumeProcessing {
                        Button("重试") {
                            handleRetryItem(item: item, in: task)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(library.queue.taskID != nil)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func handleStartTask(task: ProcessingTask) {
        if task.parameters.transcription.provider == .openAICompatible {
            let needsTranscription = task.items.contains { !$0.hasCompletedTranscription && $0.canResumeProcessing }
            if needsTranscription {
                pendingCloudStartConfirmation = true
                return
            }
        }
        do { try library.queue.start(taskID: taskID) }
        catch { errorMessage = error.localizedDescription }
    }

    private func handleRetryItem(item: TaskMediaItem, in task: ProcessingTask) {
        if task.parameters.transcription.provider == .openAICompatible, !item.hasCompletedTranscription, !item.status.isTranslationPaused {
            pendingCloudRetryItem = item
        } else {
            do { try library.queue.start(taskID: task.id, mediaID: item.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func associateCloudOriginal(for item: TaskMediaItem) {
        Task {
            do {
                try await syncSettings.associateOriginal(for: item)
                library.load()
                noticeMessage = "原媒体已成功下载并关联"
            } catch SharedDocumentError.downloadRequired {
                noticeMessage = "已请求系统下载原媒体，请稍候下载完成后再次关联"
            } catch {
                errorMessage = "关联原媒体失败：\(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func itemStatusTag(_ status: TaskMediaStatus) -> some View {
        HStack(spacing: 3) {
            switch status {
            case .completed:
                Circle().fill(Color.green).frame(width: 5, height: 5)
                Text("完成").foregroundStyle(.green)
            case .running:
                ProgressView().controlSize(.mini)
                Text("处理中").foregroundStyle(Color.voxlineAccent)
            case .pending:
                Text("等待").foregroundStyle(.secondary)
            case .cancelled:
                Text("已取消").foregroundStyle(.orange)
            case .interrupted, .translationPaused:
                Text("暂停").foregroundStyle(.orange)
            case .failed:
                Text("失败").foregroundStyle(.red)
            case .needsReview:
                Text("待校对").foregroundStyle(.orange)
            }
        }
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    private func shareTask(_ task: ProcessingTask) {
        do {
            let url = try IOSExportHelper.prepareTaskArchive(for: task)
            sharingURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private extension TranslationSettings.Engine {
    var isApple: Bool {
        if case .appleTranslation = self { return true }
        return false
    }
}
#endif
