import Foundation

/// The exporter, preview and share controller retain this owner while using its file.
final class TemporaryExportFile: Identifiable, Sendable {
    let id = UUID()
    let directory: URL
    let url: URL

    init(fileName: String) throws {
        guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxlineExports", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        url = directory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        // Destruction cannot surface a sheet error; retain cleanup failures in the system log.
        catch { NSLog("Voxline temporary export cleanup failed: %@", error.localizedDescription) }
    }
}
