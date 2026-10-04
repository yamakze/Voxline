import Foundation
import VoxlineCore

public struct ResolvedMediaBookmark: Sendable {
    public let url: URL
    public let isStale: Bool
}

/// Device-local access records are independent of task documents. Migrated media keeps the former project ID.
public actor LocalMediaStore {
    public static let shared = LocalMediaStore()
    private let directory: URL?

    public init(directory: URL? = nil) { self.directory = directory }

    public func save(projectID: UUID, identity: MediaIdentity, url: URL) throws {
        try identity.validate()
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer { if accessStarted { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        #endif
        let bookmark = try url.bookmarkData(options: options,
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        let record = MediaBookmarkRecord(formatVersion: 1, projectID: projectID, identity: identity, bookmark: bookmark)
        let target = try recordURL(projectID: projectID)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: target, options: .atomic)
    }

    public func resolve(projectID: UUID, identity: MediaIdentity) throws -> ResolvedMediaBookmark? {
        let target = try recordURL(projectID: projectID)
        let data: Data
        do { data = try Data(contentsOf: target) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let record = try JSONDecoder().decode(MediaBookmarkRecord.self, from: data)
        try record.identity.validate()
        guard record.formatVersion == 1, record.projectID == projectID,
              record.identity.matchesContent(of: identity), !record.bookmark.isEmpty else {
            throw MediaAccessError.invalidBookmark
        }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let url = try URL(resolvingBookmarkData: record.bookmark, options: options,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return ResolvedMediaBookmark(url: url, isStale: stale)
    }

    private func recordURL(projectID: UUID) throws -> URL {
        let base: URL
        if let directory { base = directory }
        else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
                .appendingPathComponent("Voxline/MediaAssociations", isDirectory: true)
        }
        return base.appendingPathComponent(projectID.uuidString).appendingPathExtension("json")
    }
}

private struct MediaBookmarkRecord: Codable {
    let formatVersion: Int
    let projectID: UUID
    let identity: MediaIdentity
    let bookmark: Data
}
