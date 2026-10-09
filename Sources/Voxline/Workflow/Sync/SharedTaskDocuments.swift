import Foundation
import Observation
import CryptoKit
import VoxlineCore

public enum SharedDocumentError: Error, LocalizedError, Equatable {
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
@Observable @MainActor
public final class SharedTaskDocuments {
    public let directory: URL
    public var discoveredURLs: [URL] = []
    private var snapshots: [URL: Data] = [:]
    private struct LocalCheckpoint: Codable {
        let url: URL
        let expectedCloudData: Data?
        let data: Data
    }
    private let recoveryDirectory: URL?
    private var pending: [URL: LocalCheckpoint] = [:]
    public enum PublicationFailure: Equatable, Sendable {
        case conflict, failed(String)
        public var message: String {
            switch self {
            case .conflict: SharedDocumentError.conflict.localizedDescription
            case .failed(let message): message
            }
        }
    }
    public private(set) var publicationErrors: [URL: PublicationFailure] = [:]
    public var pendingURLs: [URL] { Array(pending.keys) }
    public var savesCheckpointsLocally: Bool { recoveryDirectory != nil }

    public init(directory: URL, recoveryDirectory: URL? = nil) throws {
        guard directory.isFileURL else { throw SharedDocumentError.missingFolder }
        self.directory = directory
        // A separate local directory per selected shared folder keeps pending work across restart.
        self.recoveryDirectory = recoveryDirectory.map {
            $0.appendingPathComponent(SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
                .map { String(format: "%02x", $0) }.joined(), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let local = self.recoveryDirectory {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let checkpoint = try JSONDecoder().decode(LocalCheckpoint.self, from: Data(contentsOf: file))
                guard contains(checkpoint.url) else { throw SharedDocumentError.changed }
                _ = try TaskDocumentCodec.decode(checkpoint.data)
                pending[checkpoint.url.standardizedFileURL] = checkpoint
                snapshots[checkpoint.url.standardizedFileURL] = checkpoint.expectedCloudData
            }
        }
    }

    public func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL
            && url.pathExtension == "voxline"
    }

    public func read(_ url: URL, recordSnapshot: Bool = true) throws -> Data {
        if let checkpoint = pending[url.standardizedFileURL] { return checkpoint.data }
        let data = try Self.coordinatedRead(url)
        _ = try TaskDocumentCodec.decode(data)
        if recordSnapshot { snapshots[url.standardizedFileURL] = data }
        return data
    }

    /// Native notifications read and decode off the main actor; an intervening local save wins.
    func loadTask(_ url: URL) async throws -> ProcessingTask {
        let key = url.standardizedFileURL
        let localData = pending[key]?.data
        let baseline = snapshots[key]
        let (data, task) = try await Task.detached(priority: .utility) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try localData ?? Self.coordinatedRead(url)
            var task = try TaskDocumentCodec.decode(data)
            task.interruptRunningItems()
            return (data, task)
        }.value
        if localData == nil, pending[key] == nil, snapshots[key] == baseline { snapshots[key] = data }
        return task
    }

    public func write(_ data: Data, to url: URL) throws {
        _ = try TaskDocumentCodec.decode(data)
        try coordinateWrite(url, options: []) { coordinatedURL in
            try self.checkCurrentVersion(at: coordinatedURL, expected: self.snapshots[url.standardizedFileURL])
            try data.write(to: coordinatedURL, options: .atomic)
        }
        snapshots[url.standardizedFileURL] = data
    }

    /// Durable local recovery precedes cloud publication. The first cloud version remains the baseline.
    func saveCheckpoint(_ data: Data, to url: URL) throws {
        guard let recoveryDirectory else { throw SharedDocumentError.missingFolder }
        let key = url.standardizedFileURL
        let expected: Data?
        if let previous = pending[key] { expected = previous.expectedCloudData }
        else { expected = snapshots[key] }
        let checkpoint = LocalCheckpoint(url: key, expectedCloudData: expected, data: data)
        try JSONEncoder().encode(checkpoint).write(to: recoveryDirectory.appendingPathComponent(url.lastPathComponent).appendingPathExtension("json"), options: .atomic)
        pending[key] = checkpoint
    }

    public func publishCheckpoint(at url: URL) throws {
        let key = url.standardizedFileURL
        guard let checkpoint = pending[key], let recoveryDirectory else { return }
        do {
            try coordinateWrite(url, options: []) { destination in
                try Self.requireDownloaded(destination, allowingMissing: true)
                guard NSFileVersion.unresolvedConflictVersionsOfItem(at: destination)?.isEmpty != false else {
                    throw SharedDocumentError.conflict
                }
                // A crash after cloud write but before removing the recovery record is already published.
                let current: Data?
                do { current = try Data(contentsOf: destination) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { current = nil }
                if current != checkpoint.data {
                    guard current == checkpoint.expectedCloudData else { throw SharedDocumentError.changed }
                    try checkpoint.data.write(to: destination, options: .atomic)
                }
            }
            snapshots[key] = checkpoint.data
            try FileManager.default.removeItem(at: recoveryDirectory.appendingPathComponent(url.lastPathComponent).appendingPathExtension("json"))
            pending[key] = nil
            publicationErrors[key] = nil
        } catch {
            if let error = error as? SharedDocumentError, error == .changed || error == .conflict {
                publicationErrors[key] = .conflict
            } else { publicationErrors[key] = .failed(error.localizedDescription) }
            throw error
        }
    }

    public func remove(_ url: URL) throws {
        try publishCheckpoint(at: url)
        try coordinateWrite(url, options: .forDeleting) { coordinatedURL in
            try self.checkCurrentVersion(at: coordinatedURL, expected: self.snapshots[url.standardizedFileURL])
            try FileManager.default.removeItem(at: coordinatedURL)
        }
        snapshots[url.standardizedFileURL] = nil
    }

    public func checkCurrentVersion(at url: URL, expected: Data?) throws {
        try Self.requireDownloaded(url, allowingMissing: true)
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
        public enum Origin: Sendable { case shared, localRecovery, conflict }
        public let origin: Origin
    }
    private var presentedLocalData: Data?
    private var presentedCloudData: Data?
    public private(set) var versionReadErrors: [String] = []
    private var presentedVersions: [UUID: (url: URL, data: Data, task: ProcessingTask?, version: NSFileVersion?)] = [:]

    public func versions(at url: URL) throws -> [Version] {
        presentedVersions = [:]
        versionReadErrors = []
        var versions: [Version] = []
        let current: Data?
        do { current = try Self.coordinatedRead(url, allowingConflict: true) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { current = nil }
        presentedCloudData = current
        presentedLocalData = pending[url.standardizedFileURL]?.data
        var candidates: [(data: Data, origin: Version.Origin, version: NSFileVersion?)] = []
        if let current { candidates.append((current, .shared, NSFileVersion.currentVersionOfItem(at: url))) }
        if let local = pending[url.standardizedFileURL], local.data != current {
            candidates.append((local.data, .localRecovery, nil))
        }
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            candidates.append((try Data(contentsOf: version.url), .conflict, version))
        }
        for candidate in candidates {
            let id = UUID()
            let task: ProcessingTask?
            do { task = try TaskDocumentCodec.decode(candidate.data) }
            catch {
                task = nil
                versionReadErrors.append(String(localized: "版本无法读取：\(error.localizedDescription)", bundle: voxlineLocalizationBundle))
            }
            presentedVersions[id] = (url, candidate.data, task, candidate.origin == .conflict ? candidate.version : nil)
            if let task {
                versions.append(.init(id: id, task: task, modifiedAt: candidate.version?.modificationDate,
                    deviceName: candidate.version?.localizedNameOfSavingComputer, origin: candidate.origin))
            }
        }
        return versions
    }

    /// Preserve every unselected complete version before resolving native conflict markers.
    public func keepVersion(_ id: UUID, at url: URL) throws -> ProcessingTask {
        guard let selected = presentedVersions[id], selected.url == url,
              selected.task != nil, pending[url.standardizedFileURL]?.data == presentedLocalData else {
            throw SharedDocumentError.changed
        }
        var chosen = try TaskDocumentCodec.decode(selected.data)
        chosen.interruptRunningItems()
        let data = try TaskDocumentCodec.encode(chosen)
        try coordinateWrite(url, options: []) { coordinatedURL in
            let current: Data?
            do { current = try Data(contentsOf: coordinatedURL) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { current = nil }
            guard current == self.presentedCloudData else { throw SharedDocumentError.changed }
            let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinatedURL) ?? []
            let presented = self.presentedVersions.values.filter { $0.url == url }
            guard conflicts.count == presented.filter({ $0.version != nil }).count,
                  conflicts.allSatisfy({ actual in presented.contains { ($0.version?.persistentIdentifier as? NSObject)?.isEqual(actual.persistentIdentifier) == true } }) else {
                throw SharedDocumentError.changed
            }
            for version in presented where version.data != selected.data {
                if let task = version.task {
                    let copy = try task.duplicated()
                    let target = self.directory.appendingPathComponent(copy.id.uuidString).appendingPathExtension("voxline")
                    try self.write(TaskDocumentCodec.encode(copy), to: target)
                } else {
                    // Keep undecodable bytes outside the active task list before explicit replacement.
                    let archive = (self.recoveryDirectory ?? self.directory)
                        .appendingPathComponent("UnreadableVersions", isDirectory: true)
                    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
                    try version.data.write(to: archive.appendingPathComponent(UUID().uuidString).appendingPathExtension("voxline"), options: .atomic)
                }
            }
            try data.write(to: coordinatedURL, options: .atomic)
            for conflict in conflicts { conflict.isResolved = true }
            try NSFileVersion.removeOtherVersionsOfItem(at: coordinatedURL)
        }
        snapshots[url.standardizedFileURL] = data
        if pending[url.standardizedFileURL] != nil, let recoveryDirectory {
            try FileManager.default.removeItem(at: recoveryDirectory.appendingPathComponent(url.lastPathComponent).appendingPathExtension("json"))
            pending[url.standardizedFileURL] = nil
            publicationErrors[url.standardizedFileURL] = nil
        }
        presentedVersions = [:]
        versionReadErrors = []
        return chosen
    }

    public static func requestDownload(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    nonisolated private static func coordinatedRead(_ url: URL, allowingConflict: Bool = false) throws -> Data {
        try Self.requireDownloaded(url, allowingMissing: false)
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

    nonisolated private static func requireDownloaded(_ url: URL, allowingMissing: Bool) throws {
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
