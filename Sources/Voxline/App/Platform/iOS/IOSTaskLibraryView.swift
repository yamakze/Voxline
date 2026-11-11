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
    @State private var sharingFile: TemporaryExportFile?
    @State private var conflictResolutionTaskID: UUID?
    @State private var noticeMessage: String?
    @State private var fileOperation: Task<Void, Never>?

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
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { taskID in
                IOSTaskDetailView(library: library, taskID: taskID)
            }
            .toolbar {
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
                    .menuIndicator(.hidden)
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
            .sheet(item: $sharingFile) { file in
                ShareActivitySheet(activityItems: [file.url], retainedFile: file)
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
            .onDisappear { fileOperation?.cancel() }
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
            let fileStates = syncSettings.fileStates
            ForEach(library.storage.entries) { entry in
                let fileState = entry.url.flatMap { fileStates[$0.standardizedFileURL] }
                let isPlaceholder = entry.task == nil || fileState == .notDownloaded

                if let task = entry.task, !isPlaceholder {
                    Button { navigationPath.append(task.id) } label: {
                        taskRow(task, fileState: fileState)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
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
        .contentMargins(.top, 12, for: .scrollContent)
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

    private func taskRow(_ task: ProcessingTask, fileState: TaskSyncCoordinator.FileState?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(String(localized: "\(task.items.count) 媒体", bundle: appLocalizationBundle))
                    if case .running = task.status {
                        Text("·")
                        Text(String(localized: "\(task.completedCount) 完成", bundle: appLocalizationBundle))
                    } else if let started = task.startedAt {
                        Text("·")
                        Text(started.formatted(.dateTime.month(.abbreviated).day()))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let fileState { SyncFileStatusBadge(state: fileState) }
            TaskStatusBadge(status: task.status)
        }
        .contentShape(Rectangle())
    }

    private func importTask(_ url: URL) {
        fileOperation?.cancel()
        fileOperation = Task {
            do {
                let task = try await library.readImportedTask(from: url)
                try Task.checkCancellation()
                if library.task(task.id) != nil { replacement = task }
                else { try library.save(task) }
            } catch is CancellationError { return }
            catch { library.errorMessage = error.localizedDescription }
        }
    }

    private func shareTask(_ task: ProcessingTask) {
        fileOperation?.cancel()
        fileOperation = Task {
            do {
                let file = try await IOSExportHelper.prepareTaskArchive(for: task)
                try Task.checkCancellation()
                sharingFile = file
            } catch is CancellationError { return }
            catch { library.errorMessage = error.localizedDescription }
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
    @State private var sharingFile: TemporaryExportFile?
    @State private var changingCloudService = false
    @State private var selectedMediaID: UUID?
    @State private var fileOperation: Task<Void, Never>?

    private var fileState: TaskSyncCoordinator.FileState? {
        library.storage.url(for: taskID).flatMap { syncSettings.fileStates[$0.standardizedFileURL] }
    }

    var body: some View {
        if let task = library.task(taskID) {
            List {
                if fileState == .conflict {
                    Section {
                        HStack(spacing: 12) {
                            Label(String(localized: "此任务存在云端冲突版本", bundle: appLocalizationBundle), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button(String(localized: "解决冲突…", bundle: appLocalizationBundle)) {
                                showConflictSheet = true
                            }
                            .buttonStyle(.borderless)
                            .disabled(library.queue.taskID == taskID)
                        }
                        .font(.subheadline)
                    }
                }

                if let error = library.queue.errorMessage(for: taskID) {
                    Section { TaskFailureDisclosure(message: error, tint: .red) }
                }

                Section {
                    if task.items.isEmpty {
                        ContentUnavailableView(String(localized: "暂无媒体", bundle: appLocalizationBundle), systemImage: "film.stack")
                    } else {
                        ForEach(task.items) { item in
                            IOSTaskMediaRow(library: library, taskID: taskID, item: item,
                                hasTranslation: task.parameters.translation != nil,
                                provider: task.parameters.transcription.provider,
                                onOpen: { selectedMediaID = item.id },
                                onError: { errorMessage = $0 })
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
                } header: {
                    HStack(spacing: 8) {
                        Text(String(localized: "\(task.items.count) 媒体", bundle: appLocalizationBundle))
                        if case .running = task.status {
                            Text("·")
                            Text(String(localized: "\(task.completedCount) 完成", bundle: appLocalizationBundle))
                        }
                        Spacer()
                        if let state = fileState { SyncFileStatusBadge(state: state) }
                    }
                    .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 12, for: .scrollContent)
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if library.queue.taskID == taskID {
                        Button(String(localized: "取消处理", bundle: appLocalizationBundle), systemImage: "stop.fill") {
                            do { try library.queue.cancel() }
                            catch { errorMessage = error.localizedDescription }
                        }
                        .disabled(library.queue.isCancelling)
                    } else if task.items.contains(where: \.canResumeProcessing) {
                        Button(task.startedAt == nil ? String(localized: "开始处理任务", bundle: appLocalizationBundle) : String(localized: "继续未完成处理", bundle: appLocalizationBundle), systemImage: "play.fill") {
                            handleStartTask(task: task)
                        }
                        .disabled(library.queue.taskID != nil)
                    }

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
                    .menuIndicator(.hidden)
                }
            }
            .navigationDestination(item: $selectedMediaID) { mediaID in
                IOSMediaDetailView(library: library, taskID: taskID, mediaID: mediaID)
            }
            .sheet(item: $sharingFile) { file in
                ShareActivitySheet(activityItems: [file.url], retainedFile: file)
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
            .onDisappear { fileOperation?.cancel() }
        } else {
            ContentUnavailableView(String(localized: "任务不存在", bundle: appLocalizationBundle), systemImage: "tray")
        }
    }

    private func handleStartTask(task: ProcessingTask) {
        do { try library.queue.start(taskID: taskID) }
        catch { errorMessage = error.localizedDescription }
    }

    private func handleRetryItem(item: TaskMediaItem, in task: ProcessingTask) {
        do { try library.queue.start(taskID: task.id, mediaID: item.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func shareTask(_ task: ProcessingTask) {
        fileOperation?.cancel()
        fileOperation = Task {
            do {
                let file = try await IOSExportHelper.prepareTaskArchive(for: task)
                try Task.checkCancellation()
                sharingFile = file
            } catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct IOSTaskMediaRow: View {
    let library: IOSTaskLibrary
    let taskID: UUID
    let item: TaskMediaItem
    let hasTranslation: Bool
    let provider: TranscriptionSettings.Provider
    let onOpen: () -> Void
    let onError: (String) -> Void
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        Image(systemName: item.kind == .video ? "film" : "waveform")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title)
                                .font(.body.weight(.semibold))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if let media = item.media {
                                Text(TimecodeFormatter.formatDuration(milliseconds: media.durationMilliseconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(String(localized: "未关联媒体", bundle: appLocalizationBundle))
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        StatusSignal(mediaStatus: item.status)
                    }
                    .contentShape(Rectangle())
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "进入校对", bundle: appLocalizationBundle))

                if item.status.isRetryable && item.canResumeProcessing {
                    Button {
                        do { try library.queue.start(taskID: taskID, mediaID: item.id) }
                        catch { onError(error.localizedDescription) }
                    } label: {
                        Label(item.status.isTranslationPaused ? String(localized: "继续翻译", bundle: appLocalizationBundle) : String(localized: "重试", bundle: appLocalizationBundle), systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(library.queue.taskID != nil)
                }
                if library.queue.taskID == taskID, library.queue.isScheduled(mediaID: item.id) {
                    Button {
                        do { try library.queue.cancel(mediaID: item.id) }
                        catch { onError(error.localizedDescription) }
                    } label: {
                        Label(String(localized: "取消此媒体", bundle: appLocalizationBundle), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(library.queue.isCancelling && library.queue.mediaID == item.id)
                }

                Button {
                    showingDetails = true
                } label: {
                    Label(String(localized: "媒体详情", bundle: appLocalizationBundle), systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }

            if library.queue.taskID == taskID, library.queue.mediaID == item.id {
                TaskQueueProgress(taskID: taskID, mediaID: item.id, queue: library.queue)
                    .padding(.leading, 32)
            }

            switch item.status {
            case .translationPaused(let reason):
                TaskFailureDisclosure(message: String(localized: "翻译暂停：\(reason)", bundle: appLocalizationBundle), tint: .orange)
            case .failed(let reason):
                TaskFailureDisclosure(message: reason, tint: .red)
            default: EmptyView()
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                Form {
                    Section {
                        Text(item.title).textSelection(.enabled)
                        if let media = item.media {
                            LabeledContent(String(localized: "时长", bundle: appLocalizationBundle), value: TimecodeFormatter.formatDuration(milliseconds: media.durationMilliseconds))
                            LabeledContent(String(localized: "音轨", bundle: appLocalizationBundle), value: String(media.audioTrackID))
                        }
                        LabeledContent(String(localized: "字幕", bundle: appLocalizationBundle), value: item.cues.count.formatted())
                    }
                    Section(String(localized: "处理阶段", bundle: appLocalizationBundle)) {
                        if item.importedSubtitleOrigin != nil {
                            LabeledContent(String(localized: "导入原文", bundle: appLocalizationBundle)) {
                                StatusSignal(kind: StatusSignalKind(stepState: .completed))
                            }
                        } else {
                            LabeledContent(String(localized: "提取音频", bundle: appLocalizationBundle)) {
                                StatusSignal(kind: StatusSignalKind(stepState: item.extractionState))
                            }
                            LabeledContent(provider == .whisperKit ? String(localized: "本地转写", bundle: appLocalizationBundle) : String(localized: "云端转写", bundle: appLocalizationBundle)) {
                                StatusSignal(kind: StatusSignalKind(stepState: item.transcriptionState))
                            }
                        }
                        if hasTranslation {
                            LabeledContent(String(localized: "字幕翻译", bundle: appLocalizationBundle)) {
                                StatusSignal(kind: StatusSignalKind(stepState: item.translationState))
                            }
                        }
                    }
                }
                .navigationTitle(String(localized: "媒体详情", bundle: appLocalizationBundle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "完成", bundle: appLocalizationBundle)) { showingDetails = false }
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

#endif
