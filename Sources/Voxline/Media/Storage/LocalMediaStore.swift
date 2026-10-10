import Foundation
import VoxlineCore

public struct ResolvedMediaBookmark: Sendable {
    public let url: URL
    public let isStale: Bool
}

/// Device-local access records associate media with files on this device.
public actor LocalMediaStore {
    public static let shared = LocalMediaStore()
    private let directory: URL?

    public init(directory: URL? = nil) { self.directory = directory }

    public func save(mediaID: UUID, identity: MediaIdentity, url: URL) throws {
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
        let record = MediaBookmarkRecord(formatVersion: 1, mediaID: mediaID, identity: identity, bookmark: bookmark)
        let target = try recordURL(mediaID: mediaID)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: target, options: .atomic)
    }

    public func resolve(mediaID: UUID, identity: MediaIdentity) throws -> ResolvedMediaBookmark? {
        let target = try recordURL(mediaID: mediaID)
        let data: Data
        do { data = try Data(contentsOf: target) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let record = try JSONDecoder().decode(MediaBookmarkRecord.self, from: data)
        try record.identity.validate()
        guard record.formatVersion == 1, record.mediaID == mediaID,
              record.identity.matchesContent(of: identity), !record.bookmark.isEmpty else {
            throw MediaAccessError.invalidBookmark
        }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: record.bookmark, options: options,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw MediaAccessError.missingFile(identity.fileName)
        }
        return ResolvedMediaBookmark(url: url, isStale: stale)
    }

    private func recordURL(mediaID: UUID) throws -> URL {
        let base: URL
        if let directory { base = directory }
        else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
                .appendingPathComponent("Voxline/MediaAssociations", isDirectory: true)
        }
        return base.appendingPathComponent(mediaID.uuidString).appendingPathExtension("json")
    }
}

private struct MediaBookmarkRecord: Codable {
    let formatVersion: Int
    let mediaID: UUID
    let identity: MediaIdentity
    let bookmark: Data

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case mediaID = "projectID"
        case identity
        case bookmark
    }
}
