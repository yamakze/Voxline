#if os(macOS)
import VoxlineWorkflow
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore

public struct MainWindowView: View {
    @State private var library = TaskLibrary.shared
    @State private var selectedTab: NavigationItem = .allTasks
    @State private var selectedMediaID: UUID?
    @State private var configurationTask: ProcessingTask?
    @State private var isOpeningFile = false
    @State private var newTaskDraft: ProcessingTask?
    @State private var errorMessage: String?

    public init() {}

    public enum NavigationItem: Hashable {
        case allTasks
        case task(UUID)
        case models
        case settings
    }

    public var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            detailContent
        }
        .background(AppleTranslationSessionHost())
        .tint(Color.voxlineAccent)
        .frame(minWidth: 1100, minHeight: 700)
        .fileImporter(
            isPresented: $isOpeningFile,
            allowedContentTypes: [.voxlineTask]
        ) { result in
            switch result {
            case .success(let url):
                openTaskFile(at: url)
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
        .sheet(item: $newTaskDraft) { draft in
            TaskConfigurationView(task: Binding(
                get: { newTaskDraft ?? draft },
                set: { newTaskDraft = $0 }
            )) { prepared in
                try library.save(prepared)
                selectedMediaID = nil
                selectedTab = .task(prepared.id)
            }
        }
        .sheet(item: $configurationTask) { original in
            TaskConfigurationView(task: Binding(
                get: {
                    return library.task(for: original.id) ?? original
                },
                set: { configurationTask = $0 }
            )) { prepared in
                guard TaskProcessingQueue.shared.taskID != prepared.id else { throw QueueError.busy }
                try library.save(prepared)
            }
        }
        .alert("任务未保存或无法打开", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onAppear {
            library.refresh()
        }
    }

    // MARK: - Sidebar
    private var sidebarContent: some View {
        List(selection: $selectedTab) {
            Section("任务") {
                NavigationLink(value: NavigationItem.allTasks) {
                    HStack {
                        Label("全部任务", systemImage: "tray.full")
                        Spacer()
                        if !library.entries.isEmpty {
                            Text("\(library.entries.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("系统") {
                NavigationLink(value: NavigationItem.models) {
                    Label("模型管理", systemImage: "cpu")
                }

                NavigationLink(value: NavigationItem.settings) {
                    Label("翻译服务", systemImage: "character.book.closed")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    newTaskDraft = ProcessingTask()
                } label: {
                    Label("新建任务", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                Spacer()

                Button {
                    isOpeningFile = true
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("打开已有 .voxline 任务文件")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }

    // MARK: - Detail Content
    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .allTasks:
            TaskLibraryView(
                onSelectTask: { task in
                    selectedMediaID = nil
                    selectedTab = .task(task.id)
                },
                onNewTask: {
                    newTaskDraft = ProcessingTask()
                },
                onOpenFile: {
                    isOpeningFile = true
                }
            )

        case .task(let taskID):
            if let task = library.task(for: taskID) {
                taskWorkspaceView(task: task)
            } else {
                ContentUnavailableView("任务未找到", systemImage: "exclamationmark.triangle")
            }

        case .models:
            ModelManagementView()

        case .settings:
            TranslationServicesSettingsView()
        }
    }

    // MARK: - Task In-Window Workspace
    @ViewBuilder
    private func taskWorkspaceView(task: ProcessingTask) -> some View {
        Group {
            if let mediaID = selectedMediaID,
               let mediaIndex = task.items.firstIndex(where: { $0.id == mediaID }) {
                MediaDetailProofreadingView(
                    taskID: task.id,
                    initialOutputKind: task.parameters.srtOutputs[0],
                    item: task.items[mediaIndex],
                    onCommit: { updated, original in
                        try library.updateItem(updated, taskID: task.id, comparedTo: original)
                    },
                    onBack: {
                        selectedMediaID = nil
                    }
                )
            } else {
                TaskDetailView(
                    task: task,
                    isConfiguring: Binding(
                        get: { configurationTask != nil },
                        set: { configurationTask = $0 ? task : nil }
                    ),
                    selectedMediaID: $selectedMediaID
                )
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            selectedTab = .allTasks
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("全部任务")
                            }
                        }
                    }

                    ToolbarItem(placement: .principal) {
                        Text(task.title)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        if TaskProcessingQueue.shared.taskID != task.id {
                            Button("调整参数", systemImage: "slider.horizontal.3") {
                                configurationTask = task
                            }
                        }

                        if TaskProcessingQueue.shared.taskID == task.id {
                            Button(TaskProcessingQueue.shared.isCancelling ? "正在取消…" : "取消任务", systemImage: "stop.fill") {
                                do { try TaskProcessingQueue.shared.cancel() }
                                catch { errorMessage = error.localizedDescription }
                            }
                            .disabled(TaskProcessingQueue.shared.isCancelling)
                        } else {
                            Button(task.startedAt == nil ? "开始处理" : "继续处理", systemImage: "play.fill") {
                                do { try TaskProcessingQueue.shared.start(taskID: task.id) }
                                catch { errorMessage = error.localizedDescription }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(TaskProcessingQueue.shared.taskID != nil || task.items.isEmpty || task.status == .completed)
                        }
                    }
                }
            }
        }
    }

    private func openTaskFile(at url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        do {
            var task = try TaskDocumentCodec.decode(Data(contentsOf: url))
            task.interruptRunningItems()
            library.register(task, at: url)
            selectedMediaID = nil
            selectedTab = .task(task.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#endif
