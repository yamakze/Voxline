#if os(macOS)
import VoxlineWorkflow
import SwiftUI
import VoxlineCore

public struct TaskLibraryView: View {
    @State private var library = TaskLibrary.shared
    @State private var syncSettings = TaskSyncCoordinator.shared
    @State private var deletingEntry: TaskLibrary.Entry?
    @State private var conflictResolutionTaskID: UUID?
    @State private var errorMessage: String?
    @State private var targetedEntryID: String?
    @State private var hoveredEntryID: String?
    var onSelectTask: ((ProcessingTask) -> Void)?
    var onNewTask: (() -> Void)?
    var onOpenFile: (() -> Void)?

    public init(
        onSelectTask: ((ProcessingTask) -> Void)? = nil,
        onNewTask: (() -> Void)? = nil,
        onOpenFile: (() -> Void)? = nil
    ) {
        self.onSelectTask = onSelectTask
        self.onNewTask = onNewTask
        self.onOpenFile = onOpenFile
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = library.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }

                // Tasks List
                if library.entries.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "暂无任务", bundle: appLocalizationBundle), systemImage: "waveform.and.mic")
                    } description: {
                        Text(String(localized: "创建新任务开始音视频转写与双语翻译，或打开已有工程。", bundle: appLocalizationBundle))
                    } actions: {
                        HStack(spacing: 12) {
                            Button(String(localized: "新建任务", bundle: appLocalizationBundle), systemImage: "plus") {
                                onNewTask?()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)

                            Button(String(localized: "打开文件…", bundle: appLocalizationBundle), systemImage: "folder") {
                                onOpenFile?()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 70)
                } else {
                    VStack(spacing: 10) {
                        ForEach(library.entries) { entry in
                            taskEntryRow(entry: entry)
                        }
                    }
                }
            }
            .padding(28)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(String(localized: "任务队列", bundle: appLocalizationBundle))
                    .font(.headline)
            }

            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    onOpenFile?()
                } label: {
                    Image(systemName: "folder")
                }
                .help(String(localized: "打开已有 .voxline 任务文件", bundle: appLocalizationBundle))

                Button {
                    onNewTask?()
                } label: {
                    Image(systemName: "plus")
                }
                .help(String(localized: "新建任务 (⌘N)", bundle: appLocalizationBundle))
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
        .task { await library.refresh() }
        .confirmationDialog(String(localized: "删除任务？", bundle: appLocalizationBundle), isPresented: Binding(
            get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }), titleVisibility: .visible) {
            Button(String(localized: "删除任务文件", bundle: appLocalizationBundle), role: .destructive) {
                guard let entry = deletingEntry else { return }
                do {
                    guard TaskProcessingQueue.shared.taskID != entry.taskID else { throw QueueError.busy }
                    try library.delete(entryID: entry.id)
                    deletingEntry = nil
                } catch { errorMessage = error.localizedDescription }
            }
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) { deletingEntry = nil }
        } message: {
            Text(String(localized: "删除任务文件及其字幕成果，音视频源文件保留。\n\(deletingEntry?.url?.path ?? "")", bundle: appLocalizationBundle))
        }
        .alert(String(localized: "任务操作失败", bundle: appLocalizationBundle), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
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
    }

    @ViewBuilder
    private func taskEntryRow(entry: TaskLibrary.Entry) -> some View {
        let isPlaceholder = entry.task == nil

        HStack(alignment: .center, spacing: 14) {
            Image(systemName: isPlaceholder ? "icloud.and.arrow.down" : "film.stack")
                .font(.title2)
                .foregroundStyle(Color.voxlineAccent)
                .frame(width: 36, height: 36)
                .background(Color.voxlineAccent.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }

                if let task = entry.task {
                    HStack(spacing: 8) {
                        Text(String(localized: "\(task.items.count) 媒体", bundle: appLocalizationBundle))
                        Text("·")
                        Text(String(localized: "\(task.completedCount) 完成", bundle: appLocalizationBundle))
                        if task.failedCount > 0 {
                            Text("·")
                            Text(String(localized: "\(task.failedCount) 失败", bundle: appLocalizationBundle)).foregroundStyle(.red)
                        }
                        if let started = task.startedAt {
                            Text("·")
                            Text(started.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if !task.items.isEmpty && task.startedAt != nil && task.completedCount < task.items.count {
                        ProgressView(
                            value: Double(task.completedCount),
                            total: Double(task.items.count)
                        )
                        .controlSize(.mini)
                        .padding(.top, 2)
                    }
                } else if isPlaceholder {
                    Text(String(localized: "云端任务占位，点击下载即可加载完整任务成果与字幕。", bundle: appLocalizationBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let problem = entry.error {
                    Text(problem).font(.caption2).foregroundStyle(.red)
                }
            }

            Spacer()

            if isPlaceholder, let url = entry.url {
                Button(String(localized: "下载", bundle: appLocalizationBundle), systemImage: "arrow.down.circle") {
                    do {
                        try syncSettings.requestDownload(url)
                        syncSettings.refresh()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let task = entry.task {
                TaskStatusBadge(status: task.status)
            }

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlassSurface()
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(rowBorderColor(for: entry.id), lineWidth: targetedEntryID == entry.id ? 2 : 1)
        )
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                if isHovered {
                    hoveredEntryID = entry.id
                } else if hoveredEntryID == entry.id {
                    hoveredEntryID = nil
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let task = entry.task {
                onSelectTask?(task)
            } else if let url = entry.url {
                do {
                    try syncSettings.requestDownload(url)
                    syncSettings.refresh()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .focusable(entry.task != nil, interactions: .activate)
        .onKeyPress(keys: [.space, .return]) { _ in
            guard let task = entry.task else { return .ignored }
            onSelectTask?(task)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.error ?? "")
        .accessibilityAddTraits(entry.task == nil ? [] : .isButton)
        .accessibilityAction {
            if let task = entry.task {
                onSelectTask?(task)
            }
        }
        .contextMenu {
            if isPlaceholder, let url = entry.url {
                Button(String(localized: "请求下载云端任务", bundle: appLocalizationBundle), systemImage: "icloud.and.arrow.down") {
                    do {
                        try syncSettings.requestDownload(url)
                        syncSettings.refresh()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Divider()
            Button(String(localized: "删除", bundle: appLocalizationBundle), systemImage: "trash", role: .destructive) { deletingEntry = entry }
                .disabled(TaskProcessingQueue.shared.taskID == entry.taskID)
        }
        .draggable(entry.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, library.entries.contains(where: { $0.id == id }) else { return false }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                do {
                    try library.move(entryID: id, to: entry.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return true
        } isTargeted: { targeted in
            targetedEntryID = targeted ? entry.id : (targetedEntryID == entry.id ? nil : targetedEntryID)
        }
    }

    private func rowBorderColor(for entryID: String) -> Color {
        if targetedEntryID == entryID {
            return Color.voxlineAccent
        } else if hoveredEntryID == entryID {
            return Color.voxlineAccent.opacity(0.35)
        } else {
            return Color.white.opacity(0.06)
        }
    }
}

#endif
