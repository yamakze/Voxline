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

    func removeResources(of task: ProcessingTask, retaining otherTasks: [ProcessingTask]) throws {
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

        // Older flat evidence has no owner ID. Only an exact persisted checkpoint match establishes
        // attribution, and another task's matching evidence protects that file. Unattributed files stay.
        let removedEvidence = removedItems.flatMap(Self.evidence)
        if !removedEvidence.isEmpty {
            let retainedEvidence = otherTasks.flatMap { $0.items.flatMap(Self.evidence) }
            do {
                let files: [URL]
                do { files = try FileManager.default.contentsOfDirectory(at: transcription, includingPropertiesForKeys: nil) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { files = [] }
                let decoder = JSONDecoder()
                decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                for file in files where file.pathExtension == "json" {
                    do {
                        let evidence = try decoder.decode(TranscriptionEvidence.self, from: Data(contentsOf: file))
                        if removedEvidence.contains(evidence), !retainedEvidence.contains(evidence) {
                            try FileManager.default.removeItem(at: file)
                        }
                    } catch { failures.append(String(localized: "\(file.path)：无法核对或清理旧转写证据：\(error.localizedDescription)", bundle: voxlineLocalizationBundle)) }
                }
            } catch { failures.append("\(transcription.path)：\(error.localizedDescription)") }
        }
        guard failures.isEmpty else { throw TaskDeletionError.cleanupFailed(failures) }
    }

    private static func evidence(_ item: TaskMediaItem) -> [TranscriptionEvidence] {
        (item.checkpoint?.chunks ?? []).compactMap { chunk in
            switch chunk.state {
            case .completed(let result): result.evidence
            case .failed(_, let evidence), .cancelled(let evidence): evidence
            default: nil
            }
        }
    }
}

public enum TaskDeletionError: Error, LocalizedError {
    case cleanupFailed([String])
    public var errorDescription: String? {
        switch self {
        case .cleanupFailed(let failures):
            String(localized: "删除未完成，任务文件保留。部分缓存可能已清理，可修复后重试删除：\n", bundle: voxlineLocalizationBundle) + failures.joined(separator: "\n")
        }
    }
}
