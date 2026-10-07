#if os(macOS)
import VoxlineWorkflow
import SwiftUI
import VoxlineCore

public struct TaskLibraryView: View {
    @State private var library = TaskLibrary.shared
    @State private var deletingEntry: TaskLibrary.Entry?
    @State private var errorMessage: String?
    @State private var targetedEntryID: String?
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
                    VStack(spacing: 16) {
                        VoxlineAppIconView(size: 72)
                        VStack(spacing: 6) {
                            Text("暂无任务")
                                .font(.title3.weight(.medium))
                            Text("新建任务或打开已有 .voxline 文件以开始逐句转写与校对。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button("新建任务", systemImage: "plus") {
                                onNewTask?()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)

                            Button("打开文件…", systemImage: "folder") {
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
                Text("任务队列")
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
                .help("打开已有 .voxline 任务文件")

                Button {
                    onNewTask?()
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建任务 (⌘N)")
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
        .onAppear { library.refresh() }
        .confirmationDialog("删除任务？", isPresented: Binding(
            get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }), titleVisibility: .visible) {
            Button("删除任务文件", role: .destructive) {
                guard let entry = deletingEntry else { return }
                do {
                    guard TaskProcessingQueue.shared.taskID != entry.taskID else { throw QueueError.busy }
                    try library.delete(entryID: entry.id)
                    deletingEntry = nil
                } catch { errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { deletingEntry = nil }
        } message: {
            Text("删除任务文件及其字幕成果，音视频源文件保留。\n\(deletingEntry?.url?.path ?? "")")
        }
        .alert("任务操作失败", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func taskEntryRow(entry: TaskLibrary.Entry) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "film.stack")
                .font(.title2)
                .foregroundStyle(Color.voxlineAccent)
                .frame(width: 36, height: 36)
                .background(Color.voxlineAccent.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                if let task = entry.task {
                    HStack(spacing: 8) {
                        Text("\(task.items.count) 媒体")
                        Text("·")
                        Text("\(task.completedCount) 完成")
                        if task.failedCount > 0 {
                            Text("·")
                            Text("\(task.failedCount) 失败").foregroundStyle(.red)
                        }
                        if let started = task.startedAt {
                            Text("·")
                            Text(started.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if !task.items.isEmpty && task.startedAt != nil {
                        ProgressView(
                            value: Double(task.completedCount),
                            total: Double(task.items.count)
                        )
                        .controlSize(.mini)
                        .padding(.top, 2)
                    }
                }

                if let problem = entry.error {
                    Text(problem).font(.caption2).foregroundStyle(.red)
                }
            }

            Spacer()

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
                .stroke(targetedEntryID == entry.id ? Color.voxlineAccent : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let task = entry.task {
                onSelectTask?(task)
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
            Button("删除", systemImage: "trash", role: .destructive) { deletingEntry = entry }
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
}

#endif
