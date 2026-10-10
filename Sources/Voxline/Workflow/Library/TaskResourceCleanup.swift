import Foundation
import VoxlineCore

/// Only device-owned records and derived data are addressed here; source and export URLs are never inputs.
public struct TaskResourceCleanup: Sendable {
    private let associations: URL
    private let audio: URL
    private let transcription: URL

    public init(applicationSupport: URL = .applicationSupportDirectory, caches: URL = .cachesDirectory) {
        associations = applicationSupport.appendingPathComponent("Voxline/MediaAssociations", isDirectory: true)
        audio = caches.appendingPathComponent("Voxline/Audio", isDirectory: true)
        transcription = caches.appendingPathComponent("Voxline/Transcription", isDirectory: true)
    }

    func removeResources(of task: ProcessingTask, retaining otherTasks: [ProcessingTask]) -> [String] {
        let retainedIDs = Set(otherTasks.flatMap { $0.items.map(\.id) })
        let removedItems = task.items.filter { !retainedIDs.contains($0.id) }
        var failures: [String] = []
        for item in removedItems {
            let targets = [
                audio.appendingPathComponent(item.id.uuidString, isDirectory: true),
                transcription.appendingPathComponent(item.id.uuidString, isDirectory: true),
                associations.appendingPathComponent(item.id.uuidString).appendingPathExtension("json")
            ]
            for target in targets {
                do { try FileManager.default.removeItem(at: target) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
                catch { failures.append("\(target.path)：\(error.localizedDescription)") }
            }
        }

        return failures
    }
}

public enum TaskDeletionError: Error, LocalizedError {
    case cleanupFailed([String])
    public var errorDescription: String? {
        switch self {
        case .cleanupFailed(let failures):
            String(localized: "缓存清理未完成：\n", bundle: voxlineLocalizationBundle) + failures.joined(separator: "\n")
        }
    }
}
