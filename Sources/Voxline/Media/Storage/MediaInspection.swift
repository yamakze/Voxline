import AVFoundation
import CryptoKit
import Foundation
import VoxlineCore

public struct MediaTrack: Identifiable, Equatable, Sendable {
    public let id: Int32
    public let language: String?
    public let codecs: [String]
    public let isDecodable: Bool
}

public struct MediaInspection: Sendable {
    public let url: URL
    public let kind: TaskMediaKind
    public let byteCount: Int64
    public let fingerprint: String
    public let durationMilliseconds: Int64
    public let videoTracks: [MediaTrack]
    public let audioTracks: [MediaTrack]

    /// Only playback and frame rendering require video decoding; audio extraction does not.
    public func requireDecodableVideo() throws {
        guard let video = videoTracks.first else { throw MediaAccessError.noVideo }
        guard video.isDecodable else { throw MediaAccessError.undecodableVideo }
    }

    public func identity(audioTrackID: Int32) throws -> MediaIdentity {
        guard let track = audioTracks.first(where: { $0.id == audioTrackID }), track.isDecodable else {
            throw MediaAccessError.invalidAudioTrack
        }
        return try MediaIdentity(fileName: url.lastPathComponent, byteCount: byteCount, fingerprint: fingerprint,
                                 durationMilliseconds: durationMilliseconds, audioTrackID: audioTrackID)
    }
}

/// Inspect tracks and a bounded head/tail fingerprint off the main actor.
public actor MediaInspector {
    public static let shared = MediaInspector()
    private var inspectedFiles: [URL: (size: Int, modified: Date, inspection: MediaInspection)] = [:]
    public init() {}

    public nonisolated static func kind(of url: URL) throws -> TaskMediaKind {
        guard url.isFileURL else { throw MediaAccessError.unsupportedFormat }
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return .video
        case "m4a", "mp3", "wav": return .audio
        default: throw MediaAccessError.unsupportedFormat
        }
    }

    public func inspect(_ url: URL) async throws -> MediaInspection {
        let kind = try Self.kind(of: url)
        try Task.checkCancellation()
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer { if accessStarted { url.stopAccessingSecurityScopedResource() } }
        // Unscoped URLs can be directly accessible in tools. Actual reads still throw on denial.
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let size: Int
        let modified: Date
        let handle: FileHandle
        do {
            let before = try freshURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard before.isRegularFile == true, let fileSize = before.fileSize, fileSize > 0,
                  let date = before.contentModificationDate else { throw MediaAccessError.invalidFile }
            size = fileSize; modified = date
            // Always test actual access. Cached metadata must not hide revoked file permission.
            handle = try FileHandle(forReadingFrom: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw MediaAccessError.missingFile(url.lastPathComponent)
        }
        defer { try? handle.close() }
        let cacheKey = url.standardizedFileURL
        if let cached = inspectedFiles[cacheKey], cached.size == size, cached.modified == modified {
            let previous = cached.inspection
            return MediaInspection(url: url, kind: kind, byteCount: previous.byteCount, fingerprint: previous.fingerprint,
                                   durationMilliseconds: previous.durationMilliseconds,
                                   videoTracks: previous.videoTracks, audioTracks: previous.audioTracks)
        }
        inspectedFiles[cacheKey] = nil
        let asset = AVURLAsset(url: url)
        guard try await !asset.load(.hasProtectedContent) else { throw MediaAccessError.protectedMedia }
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0, seconds * 1000 < Double(Int64.max) else {
            throw MediaAccessError.invalidDuration
        }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        if kind == .video, videos.isEmpty { throw MediaAccessError.noVideo }
        guard !audios.isEmpty else { throw MediaAccessError.noAudio }
        let videoTracks = try await trackInformation(videos)
        let audioTracks = try await trackInformation(audios)
        guard audioTracks.contains(where: \.isDecodable) else { throw MediaAccessError.undecodableAudio }
        var hasher = SHA256()
        // At most 2 MiB, independent of the movie size. Size participates in identity.
        let sampleSize = 1_048_576
        let head = try handle.read(upToCount: min(size, sampleSize)) ?? Data()
        guard head.count == min(size, sampleSize) else { throw MediaAccessError.fileChanged }
        hasher.update(data: head)
        if size > sampleSize {
            let tailOffset = max(sampleSize, size - sampleSize)
            try handle.seek(toOffset: UInt64(tailOffset))
            let tail = try handle.read(upToCount: size - tailOffset) ?? Data()
            guard tail.count == size - tailOffset else { throw MediaAccessError.fileChanged }
            hasher.update(data: tail)
        }
        var refreshedURL = url
        refreshedURL.removeAllCachedResourceValues()
        let after = try refreshedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard after.fileSize == size,
              after.contentModificationDate == modified else { throw MediaAccessError.fileChanged }
        try Task.checkCancellation()
        let inspection = MediaInspection(url: url, kind: kind, byteCount: Int64(size),
                                         fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                                         durationMilliseconds: Int64((seconds * 1000).rounded()),
                                         videoTracks: videoTracks, audioTracks: audioTracks)
        inspectedFiles[cacheKey] = (size, modified, inspection)
        return inspection
    }

    /// Confirmation reuses unchanged inspections, but rejects a file replaced since selection.
    public func confirm(_ inspection: MediaInspection, audioTrackID: Int32) async throws -> MediaIdentity {
        let selected = try inspection.identity(audioTrackID: audioTrackID)
        let current = try await inspect(inspection.url).identity(audioTrackID: audioTrackID)
        guard selected.matchesContent(of: current) else { throw MediaAccessError.fileChanged }
        return current
    }

    private func trackInformation(_ tracks: [AVAssetTrack]) async throws -> [MediaTrack] {
        var result: [MediaTrack] = []
        for track in tracks {
            try Task.checkCancellation()
            let descriptions = try await track.load(.formatDescriptions)
            let codecs = descriptions.map { description in
                let code = CMFormatDescriptionGetMediaSubType(description)
                let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
                return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", code)
            }
            let extended = try await track.load(.extendedLanguageTag)
            let language = try await track.load(.languageCode)
            result.append(MediaTrack(id: track.trackID, language: extended ?? language, codecs: codecs,
                                     isDecodable: try await track.load(.isDecodable)))
        }
        return result
    }
}

public enum MediaAccessError: Error, LocalizedError, Equatable {
    case unsupportedFormat, invalidFile, protectedMedia, invalidDuration, noVideo, noAudio
    case undecodableVideo, undecodableAudio, invalidAudioTrack, fileChanged, invalidBookmark, itemChanged
    case missingFile(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: String(localized: "请选择本地 MP4／MOV／M4V 视频或 M4A／MP3／WAV 音频。", bundle: voxlineLocalizationBundle)
        case .invalidFile: String(localized: "媒体为空或不是普通文件。", bundle: voxlineLocalizationBundle)
        case .protectedMedia: String(localized: "媒体受保护，无法转写。", bundle: voxlineLocalizationBundle)
        case .invalidDuration: String(localized: "无法取得有效的媒体时长。", bundle: voxlineLocalizationBundle)
        case .noVideo: String(localized: "文件中没有视频轨。", bundle: voxlineLocalizationBundle)
        case .noAudio: String(localized: "媒体中没有音轨。", bundle: voxlineLocalizationBundle)
        case .undecodableVideo: String(localized: "当前系统无法解码视频轨。", bundle: voxlineLocalizationBundle)
        case .undecodableAudio: String(localized: "当前系统无法解码任何音轨。", bundle: voxlineLocalizationBundle)
        case .invalidAudioTrack: String(localized: "所选音轨不存在或无法解码，请重新选择。", bundle: voxlineLocalizationBundle)
        case .fileChanged: String(localized: "检查期间媒体发生变化，请重试。", bundle: voxlineLocalizationBundle)
        case .invalidBookmark: String(localized: "本地媒体关联记录无效，请重新关联媒体。", bundle: voxlineLocalizationBundle)
        case .itemChanged: String(localized: "确认期间媒体条目已改变，请重新关联。", bundle: voxlineLocalizationBundle)
        case .missingFile(let name): String(localized: "找不到“\(name)”，请重新关联媒体。", bundle: voxlineLocalizationBundle)
        }
    }
}
