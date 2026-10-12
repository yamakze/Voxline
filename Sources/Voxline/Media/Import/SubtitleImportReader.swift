import AVFoundation
import Foundation
import VoxlineCore

public struct EmbeddedSubtitleTrack: Identifiable, Equatable, Sendable {
    public let id: Int32
    public let language: String?
}

/// File I/O and timed-text sample reading stay off the UI actor.
public actor SubtitleImportReader {
    public static let shared = SubtitleImportReader()

    public func readFile(_ url: URL) throws -> [SubtitleImportEntry] {
        guard let format = SubtitleFileFormat(rawValue: url.pathExtension.lowercased()) else { throw SubtitleTrackError.unsupportedFormat }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        return try SubtitleImporter.parse(Data(contentsOf: url), format: format)
    }

    public func tracks(in url: URL) async throws -> [EmbeddedSubtitleTrack] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .subtitle) + asset.loadTracks(withMediaType: .text)
        var result: [EmbeddedSubtitleTrack] = []
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            if formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMSubtitleFormatType_3GText }) {
                let extended = try await track.load(.extendedLanguageTag)
                let language = try await track.load(.languageCode)
                result.append(.init(id: track.trackID, language: extended ?? language))
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// Adding a video imports its preferred text track; absent text tracks leave ASR as the source.
    public func automaticSelection(in url: URL, preferredLanguage: String?) async throws -> SubtitleImportSelection? {
        let available = try await tracks(in: url)
        guard let first = available.first else { return nil }
        let preferredCode = preferredLanguage.flatMap { Locale.Language(identifier: $0).languageCode }
        let track = available.first { track in
            guard let language = track.language, let preferredCode else { return false }
            return Locale.Language(identifier: language).languageCode == preferredCode
        } ?? first
        let entries = try await readEmbeddedTrack(track.id, in: url)
        return .init(entries: entries, origin: .embedded(trackID: track.id, language: track.language))
    }

    public func readEmbeddedTrack(_ trackID: Int32, in url: URL) async throws -> [SubtitleImportEntry] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .subtitle) + asset.loadTracks(withMediaType: .text)
        guard let track = tracks.first(where: { $0.trackID == trackID }),
              try await track.load(.formatDescriptions).contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMSubtitleFormatType_3GText }) else {
            throw SubtitleTrackError.unsupportedFormat
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SubtitleTrackError.unsupportedFormat }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SubtitleTrackError.invalidSample }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var entries: [SubtitleImportEntry] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Container edit/drain markers are not timed-text samples.
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else { throw SubtitleTrackError.invalidSample }
            let dataLength = CMBlockBufferGetDataLength(buffer)
            guard dataLength >= 2 else { throw SubtitleTrackError.invalidSample }
            var data = Data(count: dataLength)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: dataLength, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw SubtitleTrackError.invalidSample }
            var offset = 0
            for index in 0..<CMSampleBufferGetNumSamples(sample) {
                let size = CMSampleBufferGetSampleSize(sample, at: index)
                guard size >= 2, offset + size <= data.count else { throw SubtitleTrackError.invalidSample }
                let length = Int(data[offset]) * 256 + Int(data[offset + 1])
                guard length + 2 <= size else { throw SubtitleTrackError.invalidSample }
                let bytes = Data(data[(offset + 2)..<(offset + 2 + length)])
                offset += size
                if length == 0 { continue }
                let text: String?
                if bytes.starts(with: [0xff, 0xfe]) { text = String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian) }
                else if bytes.starts(with: [0xfe, 0xff]) { text = String(data: bytes.dropFirst(2), encoding: .utf16BigEndian) }
                else { text = String(data: bytes, encoding: .utf8) }
                guard let text else { throw SubtitleTrackError.invalidSample }
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr else { throw SubtitleTrackError.invalidSample }
                let start = try SubtitleTimeOffset.milliseconds(from: timing.presentationTimeStamp.seconds)
                let end = try SubtitleTimeOffset.milliseconds(from: CMTimeAdd(timing.presentationTimeStamp, timing.duration).seconds)
                let body = SubtitleImporter.plainText(text)
                if body.isEmpty || end <= 0 { continue }
                guard end > max(0, start) else { throw SubtitleTrackError.invalidSample }
                entries.append(.init(startMilliseconds: max(0, start), endMilliseconds: end, text: body))
            }
        }
        guard reader.status == .completed else { throw reader.error ?? SubtitleTrackError.invalidSample }
        guard !entries.isEmpty else { throw SubtitleImportError.emptyFile }
        return entries.sorted { $0.startMilliseconds < $1.startMilliseconds }
    }
}

public enum SubtitleTrackError: LocalizedError {
    case unsupportedFormat, invalidSample
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: String(localized: "请选择 SRT、VTT 或 tx3g 文本字幕轨。", bundle: voxlineLocalizationBundle)
        case .invalidSample: String(localized: "内嵌字幕的文本或时间无法读取。", bundle: voxlineLocalizationBundle)
        }
    }
}
