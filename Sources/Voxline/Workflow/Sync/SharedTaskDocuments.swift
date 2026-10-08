import Foundation
import VoxlineCore

public enum SharedDocumentError: Error, LocalizedError {
    case changed, conflict, downloadRequired, missingFolder, busy
    public var errorDescription: String? {
        switch self {
        case .changed: String(localized: "任务已在另一设备修改，请保留当前草稿并重新读取或另存副本。", bundle: voxlineLocalizationBundle)
        case .conflict: String(localized: "任务存在冲突版本，请先选择保留版本。", bundle: voxlineLocalizationBundle)
        case .downloadRequired: String(localized: "文件尚未下载，请先下载后重试。", bundle: voxlineLocalizationBundle)
        case .missingFolder: String(localized: "同步文件夹不可用，请重新选择。", bundle: voxlineLocalizationBundle)
        case .busy: String(localized: "任务正在处理，请停止后调整同步设置。", bundle: voxlineLocalizationBundle)
        }
    }
}

/// Coordinates complete Task documents; device order and worker ownership never enter this directory.
@MainActor
public final class SharedTaskDocuments {
    public let directory: URL
    public var discoveredURLs: [URL] = []
    private var snapshots: [URL: Data] = [:]

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw SharedDocumentError.missingFolder }
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL
            && url.pathExtension == "voxline"
    }

    public func read(_ url: URL, recordSnapshot: Bool = true) throws -> Data {
        let data = try coordinatedRead(url)
        _ = try TaskDocumentCodec.decode(data)
        if recordSnapshot { snapshots[url.standardizedFileURL] = data }
        return data
    }

    public func write(_ data: Data, to url: URL) throws {
        _ = try TaskDocumentCodec.decode(data)
        try coordinateWrite(url, options: []) { coordinatedURL in
            try self.checkCurrentVersion(at: coordinatedURL, expected: self.snapshots[url.standardizedFileURL])
            try data.write(to: coordinatedURL, options: .atomic)
        }
        snapshots[url.standardizedFileURL] = data
    }

    public func remove(_ url: URL) throws {
        try coordinateWrite(url, options: .forDeleting) { coordinatedURL in
            try self.checkCurrentVersion(at: coordinatedURL, expected: self.snapshots[url.standardizedFileURL])
            try FileManager.default.removeItem(at: coordinatedURL)
        }
        snapshots[url.standardizedFileURL] = nil
    }

    public func checkCurrentVersion(at url: URL, expected: Data?) throws {
        try requireDownloaded(url, allowingMissing: expected == nil)
        guard NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty != false else { throw SharedDocumentError.conflict }
        let current: Data?
        do { current = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { current = nil }
        guard current == expected else { throw SharedDocumentError.changed }
    }

    public struct Version: Identifiable, Sendable {
        public let id: UUID
        public let task: ProcessingTask
        public let modifiedAt: Date?
        public let deviceName: String?
        public let isCurrent: Bool
    }
    private var presentedVersions: [UUID: (url: URL, data: Data, version: NSFileVersion?)] = [:]

    public func versions(at url: URL) throws -> [Version] {
        presentedVersions = [:]
        var versions: [Version] = []
        let current = try coordinatedRead(url, allowingConflict: true)
        let currentID = UUID()
        presentedVersions[currentID] = (url, current, nil)
        versions.append(.init(id: currentID, task: try TaskDocumentCodec.decode(current), modifiedAt: NSFileVersion.currentVersionOfItem(at: url)?.modificationDate,
            deviceName: NSFileVersion.currentVersionOfItem(at: url)?.localizedNameOfSavingComputer, isCurrent: true))
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            let data = try Data(contentsOf: version.url)
            let id = UUID()
            presentedVersions[id] = (url, data, version)
            versions.append(.init(id: id, task: try TaskDocumentCodec.decode(data), modifiedAt: version.modificationDate,
                deviceName: version.localizedNameOfSavingComputer, isCurrent: false))
        }
        return versions
    }

    /// Preserve every unselected complete version before resolving native conflict markers.
    public func keepVersion(_ id: UUID, at url: URL) throws -> ProcessingTask {
        guard let selected = presentedVersions[id], selected.url == url,
              let original = presentedVersions.values.first(where: { $0.url == url && $0.version == nil }) else {
            throw SharedDocumentError.changed
        }
        var chosen = try TaskDocumentCodec.decode(selected.data)
        chosen.interruptRunningItems()
        let data = try TaskDocumentCodec.encode(chosen)
        try coordinateWrite(url, options: []) { coordinatedURL in
            guard try Data(contentsOf: coordinatedURL) == original.data else { throw SharedDocumentError.changed }
            let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinatedURL) ?? []
            let presented = self.presentedVersions.values.filter { $0.url == url }
            guard conflicts.count == presented.filter({ $0.version != nil }).count,
                  conflicts.allSatisfy({ actual in presented.contains { ($0.version?.persistentIdentifier as? NSObject)?.isEqual(actual.persistentIdentifier) == true } }) else {
                throw SharedDocumentError.changed
            }
            for version in presented where version.data != selected.data {
                let copy = try TaskDocumentCodec.decode(version.data).duplicated()
                let target = self.directory.appendingPathComponent(copy.id.uuidString).appendingPathExtension("voxline")
                try self.write(TaskDocumentCodec.encode(copy), to: target)
            }
            try data.write(to: coordinatedURL, options: .atomic)
            for conflict in conflicts { conflict.isResolved = true }
            try NSFileVersion.removeOtherVersionsOfItem(at: coordinatedURL)
        }
        snapshots[url.standardizedFileURL] = data
        presentedVersions = [:]
        return chosen
    }

    public static func requestDownload(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    private func coordinatedRead(_ url: URL, allowingConflict: Bool = false) throws -> Data {
        try requireDownloaded(url, allowingMissing: false)
        if !allowingConflict, NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty == false { throw SharedDocumentError.conflict }
        var result: Result<Data, any Error>?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func requireDownloaded(_ url: URL, allowingMissing: Bool) throws {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile && allowingMissing { return }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { throw SharedDocumentError.downloadRequired }
    }

    private func coordinateWrite(_ url: URL, options: NSFileCoordinator.WritingOptions,
                                 operation: (URL) throws -> Void) throws {
        var result: Result<Void, any Error>?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &error) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }
}
