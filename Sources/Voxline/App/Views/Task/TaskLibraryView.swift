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
    @State private var hoveredEntryID: String?
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

    @ViewBuilder
    private func taskEntryRow(entry: TaskLibrary.Entry) -> some View {
        let isPlaceholder = entry.task == nil

        HStack(alignment: .center, spacing: 14) {
            if isEditing {
                Button {
                    deletingEntry = entry
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

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.voxlineAccent.opacity(0.18),
                                Color.voxlineAccent.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.voxlineAccent.opacity(0.24), lineWidth: 0.8)
                    )

                Image(systemName: isPlaceholder ? "icloud.and.arrow.down" : "film.stack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.voxlineAccent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                if let task = entry.task {
                    HStack(spacing: 6) {
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
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if !task.items.isEmpty && task.startedAt != nil && task.completedCount < task.items.count {
                        ProgressView(
                            value: Double(task.completedCount),
                            total: Double(task.items.count)
                        )
                        .controlSize(.mini)
                        .tint(Color.voxlineAccent)
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

            if isEditing {
                HStack(spacing: 5) {
                    Button {
                        moveUp(entry: entry)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "上移", bundle: appLocalizationBundle))
                    .disabled(library.entries.first?.id == entry.id)

                    Button {
                        moveDown(entry: entry)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "下移", bundle: appLocalizationBundle))
                    .disabled(library.entries.last?.id == entry.id)
                }
                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .scale.combined(with: .opacity)))
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlassSurface()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(rowBorderColor(for: entry.id), lineWidth: 1.2)
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
            guard !isEditing else { return }
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
        .focusable(!isEditing && entry.task != nil, interactions: .activate)
        .onKeyPress(keys: [.space, .return]) { _ in
            guard !isEditing, let task = entry.task else { return .ignored }
            onSelectTask?(task)
            return .handled
        }
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(rowAccessibilityValue(for: entry))
        .accessibilityAddTraits(!isEditing && entry.task != nil ? .isButton : [])
        .accessibilityAction {
            guard !isEditing else { return }
            if let task = entry.task {
                onSelectTask?(task)
            }
        }
        .contextMenu {
            if let url = entry.url, syncSettings.fileStates[url.standardizedFileURL] == .conflict {
                Button(String(localized: "解决版本冲突…", bundle: appLocalizationBundle), systemImage: "arrow.triangle.merge") {
                    conflictResolutionTaskID = entry.taskID
                }
                .disabled(TaskProcessingQueue.shared.taskID == entry.taskID)
            }
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
    }

    private func rowBorderColor(for entryID: String) -> Color {
        if hoveredEntryID == entryID {
            return Color.voxlineAccent.opacity(0.45)
        } else {
            return Color.clear
        }
    }

    private func moveUp(entry: TaskLibrary.Entry) {
        guard let index = library.entries.firstIndex(where: { $0.id == entry.id }), index > 0 else { return }
        let target = library.entries[index - 1]
        withAnimation(.easeInOut(duration: 0.2)) {
            do {
                try library.move(entryID: entry.id, to: target.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func moveDown(entry: TaskLibrary.Entry) {
        guard let index = library.entries.firstIndex(where: { $0.id == entry.id }), index < library.entries.count - 1 else { return }
        let target = library.entries[index + 1]
        withAnimation(.easeInOut(duration: 0.2)) {
            do {
                try library.move(entryID: entry.id, to: target.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rowAccessibilityValue(for entry: TaskLibrary.Entry) -> String {
        var components: [String] = []
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

#endif
