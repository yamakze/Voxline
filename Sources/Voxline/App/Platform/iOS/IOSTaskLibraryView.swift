#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore

struct IOSTaskLibraryView: View {
    @State private var library = IOSTaskLibrary.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var deletingTask: ProcessingTask?
    @State private var replacement: ProcessingTask?
    @State private var newTaskDraft: ProcessingTask?
    @State private var navigationPath = NavigationPath()
    @State private var sharingURL: URL?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if library.tasks.isEmpty {
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
            Text("添加音视频开始本地转写与翻译")
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
            ForEach(library.tasks) { task in
                NavigationLink(value: task.id) {
                    taskCard(task)
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
                }
                .contextMenu {
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
                .draggable(task.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, let fromID = UUID(uuidString: item) else { return false }
                    moveTask(fromID: fromID, toID: task.id)
                    return true
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func moveTask(fromID: UUID, toID: UUID) {
        guard fromID != toID else { return }
        withAnimation {
            do {
                try library.move(taskID: fromID, to: toID)
            } catch {
                library.errorMessage = error.localizedDescription
            }
        }
    }

    private func taskCard(_ task: ProcessingTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                statusBadge(task.status)
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
    @State private var editingParameters = false
    @State private var configuringTask = false
    @State private var errorMessage: String?
    @State private var sharingURL: URL?

    var body: some View {
        if let task = library.task(taskID) {
            List {
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
            .alert("操作异常", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        } else {
            ContentUnavailableView("任务不存在", systemImage: "tray")
        }
    }

    // MARK: - 概览与控制卡片
    private func overviewCard(_ task: ProcessingTask) -> some View {
        VStack(spacing: 14) {
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
                    do { try library.queue.start(taskID: taskID) }
                    catch { errorMessage = error.localizedDescription }
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

                itemStatusTag(item.status)
            }

            // 处理步骤进度指示
            ScrollView(.horizontal, showsIndicators: false) {
                MediaProcessingStepsView(item: item, hasTranslation: task.parameters.translation != nil)
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
                            do { try library.queue.start(taskID: task.id, mediaID: item.id) }
                            catch { errorMessage = error.localizedDescription }
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
                            do { try library.queue.start(taskID: task.id, mediaID: item.id) }
                            catch { errorMessage = error.localizedDescription }
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
