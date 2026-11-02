import Foundation
import OSLog

public enum VideoExportFileError: Error, LocalizedError, Equatable {
    case sourceIsOutput, invalidFileName, fileAlreadyExists
    public var errorDescription: String? {
        switch self {
        case .sourceIsOutput: String(localized: "输出文件不能是原视频，请使用新的文件名。", bundle: voxlineLocalizationBundle)
        case .invalidFileName: String(localized: "请输入不含路径的 .mp4 文件名。", bundle: voxlineLocalizationBundle)
        case .fileAlreadyExists: String(localized: "输出文件已存在。", bundle: voxlineLocalizationBundle)
        }
    }
}

/// One unpublished output, atomically promoted only after the exporter validates its result.
final class VideoExportDestination {
    let temporaryURL: URL
    private let temporaryDirectory: URL
    private let destination: URL
    private let source: URL
    private let allowOverwrite: Bool
    private static let logger = Logger(subsystem: "dev.voxline.app", category: "VideoExport")

    init(destination: URL, source: URL, allowOverwrite: Bool) throws {
        self.destination = destination
        self.source = source
        self.allowOverwrite = allowOverwrite
        let name = destination.lastPathComponent
        guard destination.isFileURL, destination.pathExtension.lowercased() == "mp4",
              !name.contains("\\"), !name.contains("\0"),
              !destination.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VideoExportFileError.invalidFileName
        }
        try Self.validateDestination(destination, source: source, allowOverwrite: allowOverwrite)
        // Save panels authorize the chosen file, not arbitrary siblings in its parent folder.
        // Foundation supplies a writable replacement directory on the destination's volume.
        temporaryDirectory = try FileManager.default.url(for: .itemReplacementDirectory,
            in: .userDomainMask, appropriateFor: destination, create: true)
        temporaryURL = temporaryDirectory.appendingPathComponent(name)
    }

    private static func validateDestination(_ destination: URL, source: URL, allowOverwrite: Bool) throws {
        let manager = FileManager.default
        guard destination.standardizedFileURL.resolvingSymlinksInPath() != source.standardizedFileURL.resolvingSymlinksInPath() else {
            throw VideoExportFileError.sourceIsOutput
        }
        if manager.fileExists(atPath: destination.path) {
            let input = try manager.attributesOfItem(atPath: source.path)
            let output = try manager.attributesOfItem(atPath: destination.path)
            if input[.systemNumber] as? NSNumber == output[.systemNumber] as? NSNumber,
               input[.systemFileNumber] as? NSNumber == output[.systemFileNumber] as? NSNumber {
                throw VideoExportFileError.sourceIsOutput
            }
            guard allowOverwrite else { throw VideoExportFileError.fileAlreadyExists }
        }
    }

    func publish() throws {
        try Task.checkCancellation()
        try Self.validateDestination(destination, source: source, allowOverwrite: allowOverwrite)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
        } else { try FileManager.default.moveItem(at: temporaryURL, to: destination) }
    }

    func removeTemporaryFile() throws {
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    deinit {
        // Also cover setup failures before the native reader/writer enters its processing scope.
        do { try removeTemporaryFile() }
        catch { Self.logger.error("Unpublished export cleanup failed: \(error.localizedDescription)") }
    }
}
