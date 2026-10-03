import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore

extension UTType {
    static let voxlineTask = UTType(exportedAs: "dev.voxline.project", conformingTo: .json)
}

/// The iOS development entry reads the same validated documents as the Mac app.
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

    func importTask(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            var task = try TaskDocumentCodec.decode(Data(contentsOf: url))
            task.interruptRunningItems()
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            try TaskDocumentCodec.encode(task).write(
                to: directory.appendingPathComponent(task.id.uuidString).appendingPathExtension("voxline"),
                options: .atomic)
            tasks.removeAll { $0.id == task.id }
            tasks.append(task)
            tasks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct IOSTaskLibraryView: View {
    @State private var library = IOSTaskLibrary()
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Group {
                if library.tasks.isEmpty {
                    ContentUnavailableView {
                        Label("还没有任务", systemImage: "tray")
                    } description: {
                        Text("导入 Mac 生成的 Voxline 任务，查看媒体与字幕成果。")
                    } actions: {
                        Button("导入任务", systemImage: "square.and.arrow.down") { importing = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(library.tasks) { task in
                        NavigationLink {
                            IOSTaskDetailView(task: task)
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
                case .success(let url): library.importTask(from: url)
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
            .onOpenURL { library.importTask(from: $0) }
        }
    }
}

private struct IOSTaskDetailView: View {
    let task: ProcessingTask

    var body: some View {
        List {
            Section("任务") {
                LabeledContent("状态", value: task.status.label)
                LabeledContent("媒体", value: "\(task.items.count) 个")
                LabeledContent("转写模型", value: task.parameters.transcription.modelID)
            }
            Section("媒体") {
                ForEach(task.items) { item in
                    NavigationLink {
                        IOSMediaDetailView(item: item)
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
    }
}

private struct IOSMediaDetailView: View {
    let item: TaskMediaItem

    var body: some View {
        List {
            Section {
                ContentUnavailableView("媒体尚未关联", systemImage: item.kind == .audio ? "waveform" : "play.rectangle",
                                       description: Text("此版本支持查看字幕；iOS 媒体导入、播放与校对正在开发。"))
            }
            Section("字幕 · \(item.cues.count) 条") {
                if item.cues.isEmpty {
                    Text("还没有字幕成果").foregroundStyle(.secondary)
                }
                ForEach(item.cues) { cue in
                    VStack(alignment: .leading, spacing: 8) {
                        let start = Duration.milliseconds(cue.startMilliseconds)
                            .formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2, fractionalSecondsLength: 3)))
                        let end = Duration.milliseconds(cue.endMilliseconds)
                            .formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2, fractionalSecondsLength: 3)))
                        Text("\(start) → \(end)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(cue.sourceText).textSelection(.enabled)
                        switch cue.translation {
                        case .succeeded(let text, _):
                            Text(text).foregroundStyle(.secondary).textSelection(.enabled)
                            if !cue.hasCurrentTranslation {
                                Label("原文已修改，译文待更新", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        case .failed(let reason):
                            Text(reason).font(.caption).foregroundStyle(.red)
                        case .pending:
                            Text("待翻译").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    IOSTaskLibraryView()
}
