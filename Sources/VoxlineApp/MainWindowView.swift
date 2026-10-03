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
                .navigationTitle("")
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            detailContent
                .navigationTitle("")
        }
        .navigationTitle("")
        .tint(Color.voxlineAccent)
        .frame(minWidth: 1100, minHeight: 700)
        .fileImporter(
            isPresented: $isOpeningFile,
            allowedContentTypes: [.voxlineProject]
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
                set: { library.register($0, at: library.url(for: original.id)) }
            )) { prepared in
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

                ForEach(library.entries.prefix(8)) { entry in
                    if let task = entry.task {
                        NavigationLink(value: NavigationItem.task(task.id)) {
                            HStack(spacing: 8) {
                                Image(systemName: "film.stack")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                Text(entry.title)
                                    .lineLimit(1)
                                    .font(.system(size: 13))
                            }
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
            if let taskBinding = taskBinding(for: taskID) {
                taskWorkspaceView(task: taskBinding)
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
    private func taskWorkspaceView(task: Binding<ProcessingTask>) -> some View {
        VStack(spacing: 0) {
            // Top In-Window Breadcrumb / Navigation Bar
            HStack(spacing: 12) {
                Button {
                    if selectedMediaID != nil {
                        selectedMediaID = nil
                    } else {
                        selectedTab = .allTasks
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(selectedMediaID != nil ? "返回队列" : "全部任务")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                Divider().frame(height: 14)

                Text(task.wrappedValue.title)
                    .font(.headline)
                    .lineLimit(1)

                TaskStatusBadge(status: task.wrappedValue.status)

                Spacer()

                if task.wrappedValue.startedAt == nil {
                    Button("调整参数", systemImage: "slider.horizontal.3") {
                        configurationTask = task.wrappedValue
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            Divider()

            // Workbench Body
            Group {
                if let mediaID = selectedMediaID,
                   let mediaIndex = task.wrappedValue.items.firstIndex(where: { $0.id == mediaID }) {
                    MediaDetailProofreadingView(taskID: task.wrappedValue.id, item: Binding(
                        get: { task.wrappedValue.items[mediaIndex] },
                        set: { updatedItem in
                            task.wrappedValue.items[mediaIndex] = updatedItem
                        }
                    ))
                } else {
                    TaskDetailView(
                        task: task,
                        isConfiguring: Binding(
                            get: { configurationTask != nil },
                            set: { configurationTask = $0 ? task.wrappedValue : nil }
                        ),
                        selectedMediaID: $selectedMediaID
                    )
                }
            }
        }
    }

    private func taskBinding(for taskID: UUID) -> Binding<ProcessingTask>? {
        guard let loaded = library.task(for: taskID) else { return nil }
        return Binding(
            get: {
                library.task(for: taskID) ?? loaded
            },
            set: { value in
                var updated = value
                for index in updated.items.indices {
                    if updated.items[index].status == .completed,
                       updated.parameters.translation != nil,
                       !updated.items[index].cues.allSatisfy(\.hasCurrentTranslation) {
                        updated.items[index].status = .needsReview
                    }
                }
                library.register(updated, at: library.url(for: taskID))
                do { try library.save(updated) }
                catch { errorMessage = error.localizedDescription }
            }
        )
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
