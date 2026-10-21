#if os(macOS)
import VoxlineWorkflow
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineTranslation

public struct MainWindowView: View {
    @State private var library = TaskLibrary.shared
    @State private var translationStore = TranslationServiceStore.shared
    @State private var cloudStore = CloudTranscriptionServiceStore.shared
    @State private var selectedTab: NavigationItem = .allTasks
    @State private var selectedMediaID: UUID?
    @State private var configurationTask: ProcessingTask?
    @State private var isOpeningFile = false
    @State private var newTaskDraft: ProcessingTask?
    @State private var errorMessage: String?
    @State private var proofreadingSession = ProofreadingSession(previewKind: .source)

    public init() {}

    public enum NavigationItem: Hashable {
        case allTasks
        case task(UUID)
        case translationServices
        case cloudTranscriptionServices
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
        .focusedSceneValue(\.workspaceFiles, WorkspaceFileActions(
            createTask: createTask,
            openTask: openTask
        ))
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
        .alert(String(localized: "任务未保存或无法打开", bundle: appLocalizationBundle), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - Sidebar
    private var sidebarContent: some View {
        List(selection: Binding(get: { selectedTab }, set: { selectNavigation($0) })) {
            Section(String(localized: "任务", bundle: appLocalizationBundle)) {
                NavigationLink(value: NavigationItem.allTasks) {
                    HStack {
                        Label(String(localized: "全部任务", bundle: appLocalizationBundle), systemImage: "tray.full")
                        Spacer()
                        if !library.entries.isEmpty {
                            Text("\(library.entries.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section(String(localized: "服务", bundle: appLocalizationBundle)) {
                NavigationLink(value: NavigationItem.translationServices) {
                    HStack {
                        Label(String(localized: "翻译服务", bundle: appLocalizationBundle), systemImage: "character.book.closed")
                        Spacer()
                        if !translationStore.services.isEmpty {
                            Text("\(translationStore.services.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink(value: NavigationItem.cloudTranscriptionServices) {
                    HStack {
                        Label(String(localized: "云端转写", bundle: appLocalizationBundle), systemImage: "waveform.badge.mic")
                        Spacer()
                        if !cloudStore.services.isEmpty {
                            Text("\(cloudStore.services.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: createTask) {
                    Label(String(localized: "新建任务", bundle: appLocalizationBundle), systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                Spacer()

                Button(action: openTask) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "打开已有 .voxline 任务文件", bundle: appLocalizationBundle))
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
                    selectNavigation(.task(task.id))
                },
                onNewTask: createTask,
                onOpenFile: openTask
            )

        case .task(let taskID):
            if let task = library.task(for: taskID) {
                taskWorkspaceView(task: task)
            } else {
                ContentUnavailableView(String(localized: "任务未找到", bundle: appLocalizationBundle), systemImage: "exclamationmark.triangle")
            }

        case .translationServices:
            TranslationServicesSettingsView()
        case .cloudTranscriptionServices:
            CloudTranscriptionServicesSettingsView()
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
                    initialOutputKind: !task.items[mediaIndex].cues.isEmpty && task.items[mediaIndex].cues.allSatisfy(\.hasTranslation) ? .bilingual : .source,
                    item: task.items[mediaIndex],
                    session: proofreadingSession,
                    onCommit: { updated, original in
                        try library.updateItem(updated, taskID: task.id, comparedTo: original)
                    },
                    onBack: {
                        do {
                            try commitProofreadingDraft()
                            selectedMediaID = nil
                        } catch { errorMessage = error.localizedDescription }
                    }
                )
                .id("\(task.id)/\(mediaID)")
            } else {
                TaskDetailView(
                    task: task,
                    isConfiguring: Binding(
                        get: { configurationTask != nil },
                        set: { configurationTask = $0 ? task : nil }
                    ),
                    selectedMediaID: Binding(get: { selectedMediaID }, set: { mediaID in
                        if let item = task.items.first(where: { $0.id == mediaID }) {
                            proofreadingSession = ProofreadingSession(
                                previewKind: item.cues.contains(where: \.hasTranslation) ? .bilingual : .source
                            )
                        }
                        selectedMediaID = mediaID
                    })
                )
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            selectedTab = .allTasks
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .help(String(localized: "返回全部任务", bundle: appLocalizationBundle))
                    }

                    ToolbarItem(placement: .principal) {
                        Text(task.title)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        if TaskProcessingQueue.shared.taskID == task.id {
                            Button(TaskProcessingQueue.shared.isCancelling ? String(localized: "正在取消…", bundle: appLocalizationBundle) : String(localized: "取消任务", bundle: appLocalizationBundle), systemImage: "stop.fill") {
                                do { try TaskProcessingQueue.shared.cancel() }
                                catch { errorMessage = error.localizedDescription }
                            }
                            .disabled(TaskProcessingQueue.shared.isCancelling)
                        } else {
                            Button(task.startedAt == nil ? String(localized: "开始处理", bundle: appLocalizationBundle) : String(localized: "继续处理", bundle: appLocalizationBundle), systemImage: "play.fill") {
                                do { try TaskProcessingQueue.shared.start(taskID: task.id) }
                                catch { errorMessage = error.localizedDescription }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(TaskProcessingQueue.shared.taskID != nil || task.items.isEmpty || task.status == .completed)
                        }

                        if TaskProcessingQueue.shared.taskID != task.id {
                            Button(String(localized: "调整参数", bundle: appLocalizationBundle), systemImage: "slider.horizontal.3") {
                                configurationTask = task
                            }
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
            try commitProofreadingDraft()
            library.register(task, at: url)
            selectedMediaID = nil
            selectedTab = .task(task.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectNavigation(_ destination: NavigationItem) {
        guard destination != selectedTab else { return }
        do {
            try commitProofreadingDraft()
            selectedMediaID = nil
            selectedTab = destination
        } catch { errorMessage = error.localizedDescription }
    }

    private func createTask() {
        do {
            try commitProofreadingDraft()
            newTaskDraft = ProcessingTask()
        } catch { errorMessage = error.localizedDescription }
    }

    private func openTask() {
        do {
            try commitProofreadingDraft()
            isOpeningFile = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func commitProofreadingDraft() throws {
        guard proofreadingSession.editingSnapshot != nil else { return }
        guard case .task(let taskID) = selectedTab,
              let item = library.task(for: taskID)?.items.first(where: { $0.id == selectedMediaID }) else {
            throw TaskValidationError.taskChanged
        }
        try proofreadingSession.saveEditing(in: item) { updated, original in
            try library.updateItem(updated, taskID: taskID, comparedTo: original)
        }
    }
}

#endif
