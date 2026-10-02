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
    public let byteCount: Int64
    public let sha256: String
    public let durationMilliseconds: Int64
    public let videoTracks: [MediaTrack]
    public let audioTracks: [MediaTrack]

    public func identity(audioTrackID: Int32) throws -> MediaIdentity {
        guard let track = audioTracks.first(where: { $0.id == audioTrackID }), track.isDecodable else {
            throw MediaAccessError.invalidAudioTrack
        }
        return try MediaIdentity(fileName: url.lastPathComponent, byteCount: byteCount, sha256: sha256,
                                 durationMilliseconds: durationMilliseconds, audioTrackID: audioTrackID)
    }
}

/// AVFoundation and streamed hashing stay off the main actor; no whole-video copy or allocation.
public actor MediaInspector {
    public init() {}

    public func inspect(_ url: URL) async throws -> MediaInspection {
        guard url.isFileURL, ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
            throw MediaAccessError.unsupportedFormat
        }
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer { if accessStarted { url.stopAccessingSecurityScopedResource() } }
        // Unscoped URLs can be directly accessible in tools. Actual reads still throw on denial.
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard before.isRegularFile == true, let size = before.fileSize, size > 0,
              let modified = before.contentModificationDate else { throw MediaAccessError.invalidFile }
        let asset = AVURLAsset(url: url)
        guard try await !asset.load(.hasProtectedContent) else { throw MediaAccessError.protectedMedia }
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0, seconds * 1000 < Double(Int64.max) else {
            throw MediaAccessError.invalidDuration
        }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard !videos.isEmpty else { throw MediaAccessError.noVideo }
        guard !audios.isEmpty else { throw MediaAccessError.noAudio }
        let videoTracks = try await trackInformation(videos)
        let audioTracks = try await trackInformation(audios)
        guard videoTracks.allSatisfy(\.isDecodable) else { throw MediaAccessError.undecodableVideo }
        guard audioTracks.contains(where: \.isDecodable) else { throw MediaAccessError.undecodableAudio }
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        var readBytes: Int64 = 0
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
                readBytes += Int64(data.count)
            }
            try handle.close()
        } catch {
            // Preserve the original read/cancellation error; closing cannot turn it into success.
            try? handle.close()
            throw error
        }
        var refreshedURL = url
        refreshedURL.removeAllCachedResourceValues()
        let after = try refreshedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard readBytes == Int64(size), after.fileSize == size,
              after.contentModificationDate == modified else { throw MediaAccessError.fileChanged }
        try Task.checkCancellation()
        return MediaInspection(url: url, byteCount: readBytes,
                               sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                               durationMilliseconds: Int64((seconds * 1000).rounded()),
                               videoTracks: videoTracks, audioTracks: audioTracks)
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
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "请选择本地 MP4、MOV 或 M4V 视频。"
        case .invalidFile: "视频为空或不是普通文件。"
        case .protectedMedia: "视频受保护，无法转写。"
        case .invalidDuration: "无法取得有效的视频时长。"
        case .noVideo: "文件中没有视频轨。"
        case .noAudio: "视频中没有音轨。"
        case .undecodableVideo: "当前系统无法解码视频轨。"
        case .undecodableAudio: "当前系统无法解码任何音轨。"
        case .invalidAudioTrack: "所选音轨不存在或无法解码，请重新选择。"
        case .fileChanged: "检查期间视频发生变化，请重试。"
        case .invalidBookmark: "本地媒体关联记录无效，请重新关联视频。"
        case .itemChanged: "确认期间媒体条目已改变，请重新关联。"
        }
    }
}
