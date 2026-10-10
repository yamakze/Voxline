#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineWorkflow

struct IOSTaskLibraryView: View {
    @State private var library = IOSTaskLibrary.shared
    @State private var syncSettings = TaskSyncCoordinator.shared
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
            .navigationTitle(String(localized: "任务", bundle: appLocalizationBundle))
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
                            Label(String(localized: "新建任务", bundle: appLocalizationBundle), systemImage: "plus")
                        }

                        Button {
                            importing = true
                        } label: {
                            Label(String(localized: "导入任务文件…", bundle: appLocalizationBundle), systemImage: "square.and.arrow.down")
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
            .alert(String(localized: "读取失败", bundle: appLocalizationBundle), isPresented: Binding(
                get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button(String(localized: "好", bundle: appLocalizationBundle)) { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "")
            }
            .alert(String(localized: "提示", bundle: appLocalizationBundle), isPresented: Binding(
                get: { noticeMessage != nil }, set: { if !$0 { noticeMessage = nil } })) {
                Button(String(localized: "好", bundle: appLocalizationBundle)) { noticeMessage = nil }
            } message: {
                Text(noticeMessage ?? "")
            }
            .task { await library.load() }
            .onChange(of: scenePhase) { _, phase in
                library.handleScenePhaseChange(to: phase)
            }
            .onOpenURL { importTask($0) }
            .confirmationDialog(String(localized: "删除任务？", bundle: appLocalizationBundle), isPresented: Binding(
                get: { deletingTask != nil }, set: { if !$0 { deletingTask = nil } }), titleVisibility: .visible) {
                Button(String(localized: "删除", bundle: appLocalizationBundle), role: .destructive) {
                    do {
                        if let deletingTask {
                            guard library.queue.taskID != deletingTask.id else { throw CheckpointError.workRunning }
                            try library.storage.delete(taskID: deletingTask.id)
                        }
                        deletingTask = nil
                    } catch { library.errorMessage = error.localizedDescription }
                }
                Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) { deletingTask = nil }
            } message: {
                Text(String(localized: "将删除设备上的任务及其字幕，源媒体文件不受影响。", bundle: appLocalizationBundle))
            }
            .alert(String(localized: "覆盖同名任务？", bundle: appLocalizationBundle), isPresented: Binding(
                get: { replacement != nil }, set: { if !$0 { replacement = nil } })) {
                Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) { replacement = nil }
                Button(String(localized: "覆盖", bundle: appLocalizationBundle), role: .destructive) {
                    do {
                        if let replacement { try library.save(replacement) }
                        replacement = nil
                    } catch { library.errorMessage = error.localizedDescription }
                }
            } message: {
                Text(String(localized: "已存在同 ID 任务，覆盖将替换已有校对成果。", bundle: appLocalizationBundle))
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label(String(localized: "暂无任务", bundle: appLocalizationBundle), systemImage: "waveform.badge.magnifyingglass")
        } description: {
            Text(String(localized: "添加音视频开始本地或云端转写与翻译", bundle: appLocalizationBundle))
        } actions: {
            HStack(spacing: 14) {
                Button {
                    newTaskDraft = ProcessingTask()
                } label: {
                    Label(String(localized: "新建任务", bundle: appLocalizationBundle), systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    importing = true
                } label: {
                    Label(String(localized: "导入任务", bundle: appLocalizationBundle), systemImage: "square.and.arrow.down")
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
                            Label(String(localized: "删除", bundle: appLocalizationBundle), systemImage: "trash")
                        }
                        .disabled(library.queue.taskID == task.id)

                        Button {
                            shareTask(task)
                        } label: {
                            Label(String(localized: "分享", bundle: appLocalizationBundle), systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)

                        if fileState == .conflict {
                            Button {
                                conflictResolutionTaskID = task.id
                            } label: {
                                Label(String(localized: "解决冲突", bundle: appLocalizationBundle), systemImage: "exclamationmark.triangle")
                            }
                            .tint(.orange)
                        }
                    }
                    .contextMenu {
                        if fileState == .conflict {
                            Button {
                                conflictResolutionTaskID = task.id
                            } label: {
                                Label(String(localized: "解决版本冲突…", bundle: appLocalizationBundle), systemImage: "exclamationmark.triangle")
                            }
                            Divider()
                        }

                        Button {
                            shareTask(task)
                        } label: {
                            Label(String(localized: "分享任务文件 (.voxline)", bundle: appLocalizationBundle), systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            deletingTask = task
                        } label: {
                            Label(String(localized: "删除任务", bundle: appLocalizationBundle), systemImage: "trash")
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
                                    Label(String(localized: "解决版本冲突…", bundle: appLocalizationBundle), systemImage: "exclamationmark.triangle")
                                }
                                Divider()
                            }
                            if let url = entry.url {
                                Button {
                                    downloadPlaceholder(url: url)
                                } label: {
                                    Label(String(localized: "从云端下载", bundle: appLocalizationBundle), systemImage: "arrow.down.circle")
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

    private func placeholderEntryRow(entry: TaskLibrary.Entry, fileState: TaskSyncCoordinator.FileState?) -> some View {
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

                Text(String(localized: "云端任务尚未下载完整内容与字幕。", bundle: appLocalizationBundle))
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
                Button(String(localized: "解决冲突", bundle: appLocalizationBundle)) {
                    conflictResolutionTaskID = entry.taskID
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if let url = entry.url {
                Button(String(localized: "下载", bundle: appLocalizationBundle), systemImage: "arrow.down.circle") {
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
            Task { await library.load() }
            syncSettings.refresh()
            noticeMessage = String(localized: "已请求系统下载云端任务，请稍候。", bundle: appLocalizationBundle)
        } catch {
            library.errorMessage = String(localized: "请求下载失败：\(error.localizedDescription)", bundle: appLocalizationBundle)
        }
    }

    private func taskCard(_ task: ProcessingTask, entry: TaskLibrary.Entry, fileState: TaskSyncCoordinator.FileState?) -> some View {
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
                    Text(String(localized: "存在云端冲突版本", bundle: appLocalizationBundle))
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 8) {
                Text(String(localized: "\(task.items.count) 个媒体", bundle: appLocalizationBundle))
                Text("•")
                Text(String(localized: "\(task.completedCount) 完成", bundle: appLocalizationBundle))
                if task.failedCount > 0 {
                    Text("•")
                    Text(String(localized: "\(task.failedCount) 失败", bundle: appLocalizationBundle))
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
                Text(String(localized: "已完成", bundle: appLocalizationBundle)).foregroundStyle(.green)
            case .running:
                ProgressView().controlSize(.mini)
                Text(String(localized: "处理中", bundle: appLocalizationBundle)).foregroundStyle(Color.voxlineAccent)
            case .queued:
                Circle().fill(Color.blue).frame(width: 6, height: 6)
                Text(String(localized: "排队中", bundle: appLocalizationBundle)).foregroundStyle(.blue)
            case .draft:
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                Text(String(localized: "草稿", bundle: appLocalizationBundle)).foregroundStyle(.secondary)
            case .cancelled:
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text(String(localized: "已取消", bundle: appLocalizationBundle)).foregroundStyle(.orange)
            case .interrupted, .translationPaused:
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text(String(localized: "已暂停", bundle: appLocalizationBundle)).foregroundStyle(.orange)
            case .needsTranslation:
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text(String(localized: "待翻译", bundle: appLocalizationBundle)).foregroundStyle(.orange)
            case .partiallyFailed, .failed:
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text(String(localized: "失败", bundle: appLocalizationBundle)).foregroundStyle(.red)
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
    @State private var syncSettings = TaskSyncCoordinator.shared
    @State private var configuringTask = false
    @State private var showConflictSheet = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var sharingURL: URL?
    @State private var changingCloudService = false

    private var fileState: TaskSyncCoordinator.FileState? {
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
                                Text(String(localized: "存在云端冲突版本", bundle: appLocalizationBundle))
                                    .font(.subheadline.bold())
                                Text(String(localized: "另一设备在离线期间保存了不同版本。", bundle: appLocalizationBundle))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(String(localized: "解决冲突…", bundle: appLocalizationBundle)) {
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
                Section(String(localized: "媒体条目 (\(task.items.count))", bundle: appLocalizationBundle)) {
                    if task.items.isEmpty {
                        ContentUnavailableView(String(localized: "暂无媒体条目", bundle: appLocalizationBundle), systemImage: "film.stack",
                                               description: Text(String(localized: "请点击右上角参数菜单添加音视频。", bundle: appLocalizationBundle)))
                    } else {
                        ForEach(task.items) { item in
                            NavigationLink {
                                IOSMediaDetailView(library: library, taskID: taskID, mediaID: item.id)
                            } label: {
                                mediaItemCard(item: item, task: task)
                            }
                            .contextMenu {
                                if item.status.isRetryable && item.canResumeProcessing {
                                    Button(item.status.isTranslationPaused ? String(localized: "继续翻译", bundle: appLocalizationBundle) : String(localized: "重试", bundle: appLocalizationBundle), systemImage: "arrow.clockwise") {
                                        handleRetryItem(item: item, in: task)
                                    }
                                    .disabled(library.queue.taskID != nil)
                                }
                                if library.queue.taskID == task.id, library.queue.isScheduled(mediaID: item.id) {
                                    Button(String(localized: "取消此媒体", bundle: appLocalizationBundle), systemImage: "stop.circle") {
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
                            Label(String(localized: "分享任务文件 (.voxline)", bundle: appLocalizationBundle), systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        if task.startedAt == nil {
                            Button {
                                configuringTask = true
                            } label: {
                                Label(String(localized: "媒体管理与准备…", bundle: appLocalizationBundle), systemImage: "film")
                            }
                            .disabled(library.queue.taskID == taskID)
                        }

                        Button {
                            configuringTask = true
                        } label: {
                            Label(String(localized: "调整参数…", bundle: appLocalizationBundle), systemImage: "slider.horizontal.3")
                        }
                        .disabled(library.queue.taskID == taskID)

                        if task.parameters.transcription.provider == .openAICompatible {
                            Button {
                                changingCloudService = true
                            } label: {
                                Label(String(localized: "更换转写服务…", bundle: appLocalizationBundle), systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(library.queue.taskID == taskID)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: Binding(get: { sharingURL.map { SharePayload(url: $0) } }, set: { sharingURL = $0?.url })) { payload in
                ShareActivitySheet(activityItems: [payload.url])
            }
            .sheet(isPresented: $changingCloudService) {
                ChangeCloudTranscriptionServiceSheet(task: task) { updated in
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
                    }
                )
            }
            .sheet(isPresented: $showConflictSheet) {
                TaskConflictResolutionSheet(taskID: taskID, draftTask: task) {
                    syncSettings.refresh()
                }
            }
            .alert(String(localized: "操作异常", bundle: appLocalizationBundle), isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(String(localized: "好", bundle: appLocalizationBundle)) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .alert(String(localized: "提示", bundle: appLocalizationBundle), isPresented: Binding(
                get: { noticeMessage != nil }, set: { if !$0 { noticeMessage = nil } })) {
                Button(String(localized: "好", bundle: appLocalizationBundle)) { noticeMessage = nil }
            } message: { Text(noticeMessage ?? "") }
        } else {
            ContentUnavailableView(String(localized: "任务不存在", bundle: appLocalizationBundle), systemImage: "tray")
        }
    }

    // MARK: - 概览与控制卡片
    private func overviewCard(_ task: ProcessingTask) -> some View {
        VStack(spacing: 16) {
            // 指标行：均分结构化展示
            HStack(spacing: 0) {
                metricTile(
                    value: "\(task.items.count)",
                    label: String(localized: "媒体总数", bundle: appLocalizationBundle),
                    color: .primary
                )

                Spacer()

                metricTile(
                    value: "\(task.completedCount)",
                    label: String(localized: "已完成", bundle: appLocalizationBundle),
                    color: .green
                )

                if task.failedCount > 0 {
                    Spacer()
                    metricTile(
                        value: "\(task.failedCount)",
                        label: String(localized: "失败项", bundle: appLocalizationBundle),
                        color: .red
                    )
                }

                Spacer()

                let totalCues = task.items.reduce(0) { $0 + $1.cues.count }
                metricTile(
                    value: totalCues.formatted(),
                    label: String(localized: "字幕总句", bundle: appLocalizationBundle),
                    color: .primary
                )
            }
            .padding(.horizontal, 8)

            // 处理控制按钮或正在运行指示
            if library.queue.taskID == taskID {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(library.queue.isCancelling ? String(localized: "正在取消…", bundle: appLocalizationBundle) : (library.queue.progressText ?? String(localized: "处理中…", bundle: appLocalizationBundle)))
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
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) {
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
                if canResume {
                    Button {
                        handleStartTask(task: task)
                    } label: {
                        HStack {
                            Spacer()
                            Label(task.startedAt == nil ? String(localized: "开始处理任务", bundle: appLocalizationBundle) : String(localized: "继续未完成处理", bundle: appLocalizationBundle),
                                  systemImage: task.startedAt == nil ? "play.fill" : "arrow.clockwise")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.queue.taskID != nil)
                } else if !task.items.isEmpty && task.completedCount == task.items.count {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "全部媒体已处理完成", bundle: appLocalizationBundle))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
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

    private func metricTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 56)
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
                            Text(TimecodeFormatter.formatDuration(milliseconds: media.durationMilliseconds))
                            Text("•")
                            Text(String(localized: "音轨 \(media.audioTrackID)", bundle: appLocalizationBundle))
                            Text("•")
                            Text(String(localized: "\(item.cues.count) 句", bundle: appLocalizationBundle))
                        } else {
                            Text(String(localized: "未关联媒体", bundle: appLocalizationBundle))
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

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
                    Text(String(localized: "翻译暂停：\(reason)", bundle: appLocalizationBundle))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer()
                    if item.status.isRetryable && item.canResumeProcessing {
                        Button(String(localized: "继续", bundle: appLocalizationBundle)) {
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
                        Button(String(localized: "重试", bundle: appLocalizationBundle)) {
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
        do { try library.queue.start(taskID: taskID) }
        catch { errorMessage = error.localizedDescription }
    }

    private func handleRetryItem(item: TaskMediaItem, in task: ProcessingTask) {
        do { try library.queue.start(taskID: task.id, mediaID: item.id) }
        catch { errorMessage = error.localizedDescription }
    }

    @ViewBuilder
    private func itemStatusTag(_ status: TaskMediaStatus) -> some View {
        HStack(spacing: 3) {
            switch status {
            case .completed:
                Circle().fill(Color.green).frame(width: 5, height: 5)
                Text(String(localized: "完成", bundle: appLocalizationBundle)).foregroundStyle(.green)
            case .running:
                ProgressView().controlSize(.mini)
                Text(String(localized: "处理中", bundle: appLocalizationBundle)).foregroundStyle(Color.voxlineAccent)
            case .pending:
                Text(String(localized: "等待", bundle: appLocalizationBundle)).foregroundStyle(.secondary)
            case .cancelled:
                Text(String(localized: "已取消", bundle: appLocalizationBundle)).foregroundStyle(.orange)
            case .interrupted, .translationPaused:
                Text(String(localized: "暂停", bundle: appLocalizationBundle)).foregroundStyle(.orange)
            case .failed:
                Text(String(localized: "失败", bundle: appLocalizationBundle)).foregroundStyle(.red)
            case .needsTranslation:
                Text(String(localized: "待翻译", bundle: appLocalizationBundle)).foregroundStyle(.orange)
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
