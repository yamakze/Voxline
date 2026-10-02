import SwiftUI
import VoxlineCore

struct TaskLibraryView: View {
    @State private var library = TaskLibrary.shared
    @State private var isOpening = false
    @State private var error: String?
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            List {
                Label("本地任务", systemImage: "tray.full").foregroundStyle(.tint)
                Text("最近打开的任务文档").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Voxline")
            .navigationSplitViewColumnWidth(200)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务").font(.largeTitle.bold())
                        Text("一批媒体，一次参数。字幕成果随任务保存在本地。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("新建任务", systemImage: "plus") { newDocument(VoxlineDocument()) }
                        .buttonStyle(.borderedProminent).keyboardShortcut("n")
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if library.entries.isEmpty {
                    ContentUnavailableView("还没有任务", systemImage: "tray",
                                           description: Text("新建任务并添加本地视频，或打开已有 .voxline 文件。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(library.entries) { entry in
                        HStack(spacing: 16) {
                            Image(systemName: "film.stack").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.title).font(.headline)
                                if let task = entry.task {
                                    Text("\(task.items.count) 个媒体 · \(task.status.label) · \(task.completedCount) 完成 · \(task.failedCount) 失败")
                                        .font(.callout).foregroundStyle(.secondary)
                                    if !task.items.isEmpty {
                                        ProgressView(value: Double(task.completedCount), total: Double(task.items.count))
                                            .accessibilityLabel("完成媒体数量")
                                    }
                                }
                                if let problem = entry.error { Text(problem).font(.callout).foregroundStyle(.red) }
                                Text(entry.url?.lastPathComponent ?? "尚未保存的文档")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let url = entry.url {
                                Button("打开任务") { Task { await open(at: url) } }
                            } else {
                                Text("已在文档窗口打开").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 12)
                    }.listStyle(.inset)
                }
            }.padding(28)
            .navigationTitle("本地任务")
            .toolbar {
                Button("打开任务…", systemImage: "folder") { isOpening = true }
                Button("刷新", systemImage: "arrow.clockwise") { library.refresh() }
            }
        }
        .frame(minWidth: 850, minHeight: 540)
        .onAppear { library.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { library.refresh() } }
        .fileImporter(isPresented: $isOpening, allowedContentTypes: [.voxlineProject]) { result in
            switch result {
            case .success(let url): Task { await open(at: url) }
            case .failure(let problem): error = problem.localizedDescription
            }
        }
    }

    private func open(at url: URL) async {
        do { try await openDocument(at: url); error = nil; library.refresh() }
        catch { self.error = error.localizedDescription }
    }
}
