import SwiftUI
import VoxlineCore

public struct TaskLibraryView: View {
    @State private var library = TaskLibrary.shared
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
                // Header
                HStack(alignment: .center) {
                    Text("任务列表")
                        .font(.largeTitle.bold())

                    Spacer()

                    HStack(spacing: 10) {
                        Button("打开文件…", systemImage: "folder") {
                            onOpenFile?()
                        }
                        .buttonStyle(.bordered)

                        Button("新建任务", systemImage: "plus") {
                            onNewTask?()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("n", modifiers: [.command])
                    }
                }

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
        .onAppear { library.refresh() }
    }

    @ViewBuilder
    private func taskEntryRow(entry: TaskLibrary.Entry) -> some View {
        Button {
            if let task = entry.task {
                onSelectTask?(task)
            }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "film.stack")
                    .font(.title2)
                    .foregroundStyle(Color.voxlineAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.voxlineAccent.opacity(0.12), in: .circle)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(entry.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if let task = entry.task {
                            TaskStatusBadge(status: task.status)
                        }
                    }

                    if let task = entry.task {
                        HStack(spacing: 10) {
                            Text("\(task.items.count) 个媒体")
                            Text("\(task.completedCount) 完成")
                            if task.failedCount > 0 {
                                Text("\(task.failedCount) 失败").foregroundStyle(.red)
                            }
                            if let started = task.startedAt {
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

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .liquidGlassSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
