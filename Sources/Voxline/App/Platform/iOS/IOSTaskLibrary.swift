#if os(iOS)
import Foundation
import Observation
import VoxlineCore

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


#endif
