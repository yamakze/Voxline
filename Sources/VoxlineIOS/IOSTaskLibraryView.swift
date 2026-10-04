import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore

extension UTType {
    static let voxlineTask = UTType(exportedAs: "dev.voxline.project", conformingTo: .json)
}

/// Device-local task copies are independent of the imported source document.
@MainActor @Observable
final class IOSTaskLibrary {
    private(set) var tasks: [ProcessingTask] = []
    var errorMessage: String?

    func load() {
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "voxline" }
            var loaded: [ProcessingTask] = []
            var failures: [String] = []
            for url in urls {
                do {
                    var task = try TaskDocumentCodec.decode(Data(contentsOf: url))
                    task.interruptRunningItems()
                    loaded.append(task)
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            tasks = loaded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func readImportedTask(from url: URL) throws -> ProcessingTask {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var task = try TaskDocumentCodec.decode(Data(contentsOf: url))
        task.interruptRunningItems()
        return task
    }

    func save(_ task: ProcessingTask) throws {
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        try TaskDocumentCodec.encode(task).write(
            to: directory.appendingPathComponent(task.id.uuidString).appendingPathExtension("voxline"), options: .atomic)
        tasks.removeAll { $0.id == task.id }
        tasks.append(task)
        tasks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func updateItem(_ item: TaskMediaItem, taskID: UUID, comparedTo original: TaskMediaItem) throws {
        guard var task = tasks.first(where: { $0.id == taskID }),
              let index = task.items.firstIndex(where: { $0.id == original.id }),
              task.items[index] == original, item.id == original.id else { throw TaskValidationError.taskChanged }
        task.items[index] = item
        try save(task)
    }

    func task(_ id: UUID) -> ProcessingTask? { tasks.first { $0.id == id } }
}

struct IOSTaskLibraryView: View {
    @State private var library = IOSTaskLibrary()
    @State private var importing = false
    @State private var replacement: ProcessingTask?

    var body: some View {
        NavigationStack {
            Group {
                if library.tasks.isEmpty {
                    ContentUnavailableView {
                        Label("还没有任务", systemImage: "tray")
                    } description: {
                        Text("导入 Mac 的 .voxline 任务成果，再关联本地音视频进行播放校对。")
                    } actions: {
                        Button("导入任务", systemImage: "square.and.arrow.down") { importing = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(library.tasks) { task in
                        NavigationLink {
                            IOSTaskDetailView(library: library, taskID: task.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title).font(.headline)
                                Text("\(task.items.count) 个媒体 · \(task.completedCount) 完成 · \(task.failedCount) 失败")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text(task.status.label).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("任务")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("导入任务", systemImage: "square.and.arrow.down") { importing = true }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.voxlineTask, .json]) { result in
                switch result {
                case .success(let url): importTask(url)
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            .alert("任务读取失败", isPresented: Binding(
                get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button("好") { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "")
            }
            .task { library.load() }
            .onOpenURL { importTask($0) }
            .alert("替换本地任务？", isPresented: Binding(
                get: { replacement != nil }, set: { if !$0 { replacement = nil } })) {
                Button("取消", role: .cancel) { replacement = nil }
                Button("替换", role: .destructive) {
                    do {
                        if let replacement { try library.save(replacement) }
                        replacement = nil
                    } catch { library.errorMessage = error.localizedDescription }
                }
            } message: { Text("同 ID 任务已存在。替换会覆盖设备上的字幕校对，请确认已保留所需成果。") }
        }
    }

    private func importTask(_ url: URL) {
        do {
            let task = try library.readImportedTask(from: url)
            if library.task(task.id) != nil { replacement = task }
            else { try library.save(task) }
        } catch { library.errorMessage = error.localizedDescription }
    }

}

private struct IOSTaskDetailView: View {
    let library: IOSTaskLibrary
    let taskID: UUID

    var body: some View {
        if let task = library.task(taskID) {
            List {
                Section("任务") {
                    LabeledContent("状态", value: task.status.label)
                    LabeledContent("媒体", value: "\(task.items.count) 个")
                    LabeledContent("转写模型", value: task.parameters.transcription.modelID)
                }
                Section("媒体") {
                    ForEach(task.items) { item in
                        NavigationLink {
                            IOSMediaDetailView(library: library, taskID: taskID, mediaID: item.id)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title)
                                    Text(item.status.label).font(.caption).foregroundStyle(.secondary)
                                    Text("\(item.cues.count) 条字幕").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: item.kind == .audio ? "waveform" : "film")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
        } else { ContentUnavailableView("任务不存在", systemImage: "tray") }
    }
}
