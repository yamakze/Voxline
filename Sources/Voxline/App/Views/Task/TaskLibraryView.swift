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
    @State private var isEditing = false
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
                    LazyVStack(spacing: 0) {
                        ForEach(library.entries) { entry in
                            TaskLibraryRow(
                                entry: entry,
                                isEditing: isEditing,
                                isFirst: library.entries.first?.id == entry.id,
                                isLast: library.entries.last?.id == entry.id,
                                hasConflict: entry.url.map { syncSettings.fileStates[$0.standardizedFileURL] == .conflict } ?? false,
                                onSelectTask: { onSelectTask?($0) },
                                onDelete: { deletingEntry = entry },
                                onMove: { move(entry: entry, offset: $0) },
                                onDownload: requestDownload,
                                onResolveConflict: { conflictResolutionTaskID = entry.taskID }
                            )
                            if entry.id != library.entries.last?.id {
                                Divider().padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(4)
                    .nativeControlSurface(cornerRadius: 14)
                }
            }
            .frame(maxWidth: 960)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(String(localized: "全部任务", bundle: appLocalizationBundle))
                    .font(.headline)
            }

            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
            }

            ToolbarItem(placement: .primaryAction) {
                if !library.entries.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isEditing.toggle()
                        }
                    } label: {
                        Text(isEditing ? String(localized: "完成", bundle: appLocalizationBundle) : String(localized: "编辑", bundle: appLocalizationBundle))
                            .fontWeight(isEditing ? .semibold : .regular)
                    }
                }
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
                    if library.entries.isEmpty {
                        isEditing = false
                    }
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

    private func requestDownload(_ url: URL) {
        do {
            try syncSettings.requestDownload(url)
            syncSettings.refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private func move(entry: TaskLibrary.Entry, offset: Int) {
        guard let index = library.entries.firstIndex(where: { $0.id == entry.id }),
              library.entries.indices.contains(index + offset) else { return }
        let target = library.entries[index + offset]
        withAnimation(.easeInOut(duration: 0.2)) {
            do { try library.move(entryID: entry.id, to: target.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct TaskLibraryRow: View {
    let entry: TaskLibrary.Entry
    let isEditing: Bool
    let isFirst: Bool
    let isLast: Bool
    let hasConflict: Bool
    let onSelectTask: (ProcessingTask) -> Void
    let onDelete: () -> Void
    let onMove: (Int) -> Void
    let onDownload: (URL) -> Void
    let onResolveConflict: () -> Void

    var body: some View {
        let isPlaceholder = entry.task == nil

        HStack(alignment: .center, spacing: 14) {
            if isEditing {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help(String(localized: "删除任务", bundle: appLocalizationBundle))
                .disabled(TaskProcessingQueue.shared.taskID == entry.taskID)
                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .scale.combined(with: .opacity)))
            }

            if isPlaceholder {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let task = entry.task {
                    HStack(spacing: 8) {
                        Text(String(localized: "\(task.items.count) 媒体", bundle: appLocalizationBundle))
                        if case .running = task.status {
                            Text("·")
                            Text(String(localized: "\(task.completedCount) 完成", bundle: appLocalizationBundle))
                        } else if let started = task.startedAt {
                            Text("·")
                            Text(started.formatted(.dateTime.month(.abbreviated).day()))
                                .help(started.formatted(date: .complete, time: .shortened))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else if isPlaceholder {
                    Text(String(localized: "云端任务尚未下载完整内容与字幕。", bundle: appLocalizationBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let problem = entry.error {
                    Text(problem)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if isPlaceholder, let url = entry.url {
                    Button {
                        onDownload(url)
                    } label: {
                        Label(String(localized: "下载", bundle: appLocalizationBundle), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let task = entry.task {
                    TaskStatusBadge(status: task.status)
                }

                if isEditing {
                    HStack(spacing: 4) {
                        Button {
                            onMove(-1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "上移", bundle: appLocalizationBundle))
                        .disabled(isFirst)

                        Button {
                            onMove(1)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "下移", bundle: appLocalizationBundle))
                        .disabled(isLast)
                    }
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .scale.combined(with: .opacity)))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .modifier(TaskEntryHoverBorder())
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return }
            if let task = entry.task {
                onSelectTask(task)
            } else if let url = entry.url {
                onDownload(url)
            }
        }
        .focusable(!isEditing, interactions: .activate)
        .onKeyPress(keys: [.space, .return]) { _ in
            guard !isEditing else { return .ignored }
            if let task = entry.task {
                onSelectTask(task)
                return .handled
            } else if let url = entry.url {
                onDownload(url)
                return .handled
            }
            return .ignored
        }
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(!isEditing ? .isButton : [])
        .accessibilityAction {
            guard !isEditing else { return }
            if let task = entry.task {
                onSelectTask(task)
            } else if let url = entry.url {
                onDownload(url)
            }
        }
        .contextMenu {
            if hasConflict {
                Button(String(localized: "解决版本冲突…", bundle: appLocalizationBundle), systemImage: "arrow.triangle.merge") {
                    onResolveConflict()
                }
                .disabled(TaskProcessingQueue.shared.taskID == entry.taskID)
            }
            if isPlaceholder, let url = entry.url {
                Button(String(localized: "请求下载云端任务", bundle: appLocalizationBundle), systemImage: "icloud.and.arrow.down") {
                    onDownload(url)
                }
            }
            Divider()
            Button(String(localized: "删除", bundle: appLocalizationBundle), systemImage: "trash", role: .destructive) { onDelete() }
                .disabled(TaskProcessingQueue.shared.taskID == entry.taskID)
        }
    }

    private var accessibilityValue: String {
        var components: [String] = []
        if hasConflict {
            components.append(String(localized: "版本冲突", bundle: appLocalizationBundle))
        }
        if let task = entry.task {
            components.append(task.status.label)
            components.append(String(localized: "\(task.items.count) 媒体", bundle: appLocalizationBundle))
            components.append(String(localized: "\(task.completedCount) 完成", bundle: appLocalizationBundle))
            if task.failedCount > 0 {
                components.append(String(localized: "\(task.failedCount) 失败", bundle: appLocalizationBundle))
            }
        } else {
            components.append(String(localized: "云端占位", bundle: appLocalizationBundle))
        }
        if let problem = entry.error, !problem.isEmpty {
            components.append(problem)
        }
        return components.joined(separator: " · ")
    }
}

private struct TaskEntryHoverBorder: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.voxlineAccent.opacity(0.04) : Color.clear)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
    }
}

#endif
