import AVFoundation
import AudioToolbox
import Foundation
import VoxlineCore

public enum AudioExtractionProgress: Sendable {
    case cacheInvalidated(reason: String)
    case extracting(fraction: Double)
}

public struct ExtractedAudio: Sendable {
    public let chunks: [TranscriptionAudio]
    public let reusedCache: Bool
}

/// Disk-backed PCM chunks keep both decoding and subsequent ASR inputs bounded.
public actor AudioExtractor {
    public static let shared = AudioExtractor()
    private let directory: URL?
    private static let sampleRate: Int32 = 16_000
    private static let maximumChunkFrames: Int64 = 120 * 16_000

    public init(directory: URL? = nil) { self.directory = directory }

    public func extract(mediaURL: URL, mediaID: UUID, identity: MediaIdentity,
                        onProgress: @Sendable (AudioExtractionProgress) -> Void = { _ in }) async throws -> ExtractedAudio {
        try Task.checkCancellation()
        let accessStarted = mediaURL.startAccessingSecurityScopedResource()
        defer { if accessStarted { mediaURL.stopAccessingSecurityScopedResource() } }
        var sourceURL = mediaURL
        sourceURL.removeAllCachedResourceValues()
        let before = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let inspection = try await MediaInspector.shared.inspect(mediaURL)
        let current = try inspection.identity(audioTrackID: identity.audioTrackID)
        guard identity.matchesContent(of: current) else { throw MediaAccessError.fileChanged }
        let asset = AVURLAsset(url: mediaURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first(where: { $0.trackID == identity.audioTrackID }) else {
            throw MediaAccessError.invalidAudioTrack
        }
        let segments = try await track.load(.segments)
        guard let firstContent = segments.first(where: { !$0.isEmpty }) else { throw AudioExtractionError.emptyAudio }
        let trackRange = try await track.load(.timeRange)
        let mediaDuration = try await asset.load(.duration)
        let sourceRange = CMTimeRange(start: firstContent.timeMapping.target.start,
            end: CMTimeMinimum(trackRange.end, mediaDuration))
        guard sourceRange.isValid, sourceRange.duration > .zero else { throw AudioExtractionError.emptyAudio }
        // Decoders can return a complete final AAC packet past the requested media endpoint.
        // Only PCM frames within the native source range belong to the transcription timeline.
        let sourceEndFrame = CMTimeConvertScale(sourceRange.end, timescale: Self.sampleRate, method: .roundTowardZero).value
        try Task.checkCancellation()
        let base: URL
        if let directory { base = directory }
        else {
            base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
                .appendingPathComponent("Voxline/Audio", isDirectory: true)
        }
        let root = base.appendingPathComponent(mediaID.uuidString, isDirectory: true)
        let manifestURL = root.appendingPathComponent("audio.json")
        if FileManager.default.fileExists(atPath: root.path) {
            do {
                let record = try JSONDecoder().decode(AudioExtractionRecord.self, from: Data(contentsOf: manifestURL))
                guard record.formatVersion == 1, record.identity.matchesContent(of: identity), !record.chunks.isEmpty else {
                    throw AudioExtractionError.invalidCache
                }
                var previousEnd: Int64 = 0
                for (index, chunk) in record.chunks.enumerated() {
                    try Task.checkCancellation()
                    let (endFrame, overflow) = chunk.sourceStartFrame.addingReportingOverflow(chunk.frameCount)
                    guard !overflow, chunk.sourceStartFrame >= previousEnd, chunk.frameCount > 0,
                          chunk.frameCount <= Self.maximumChunkFrames,
                          Double(endFrame) / 16 <= Double(identity.durationMilliseconds) + 1 else {
                        throw AudioExtractionError.invalidCache
                    }
                    let url = Self.chunkURL(in: root, index: index)
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, let size = values.fileSize, size > 44 else {
                        throw AudioExtractionError.invalidCache
                    }
                    let file: AVAudioFile
                    do { file = try AVAudioFile(forReading: url) }
                    catch {
                        // Only explicit format failures invalidate derived PCM; other errors propagate.
                        let audioError = error as NSError
                        guard audioError.domain == NSOSStatusErrorDomain || audioError.domain == "com.apple.coreaudio.avfaudio",
                              [kAudioFileUnsupportedFileTypeError, kAudioFileUnsupportedDataFormatError,
                               kAudioFileInvalidFileError, kAudioFileInvalidChunkError, kAudioFileEndOfFileError]
                                .contains(where: { Int($0) == audioError.code }) else { throw error }
                        throw AudioExtractionError.invalidCache
                    }
                    guard file.length == chunk.frameCount, file.processingFormat.sampleRate == 16_000,
                          file.processingFormat.channelCount == 1, file.fileFormat.commonFormat == .pcmFormatFloat32 else {
                        throw AudioExtractionError.invalidCache
                    }
                    previousEnd = endFrame
                }
                sourceURL.removeAllCachedResourceValues()
                let after = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
                    throw MediaAccessError.fileChanged
                }
                let result = try record.audio(in: root, reusedCache: true)
                onProgress(.extracting(fraction: 1))
                return result
            } catch is DecodingError {
                onProgress(.cacheInvalidated(reason: String(localized: "音频缓存记录损坏，重新提取。", bundle: voxlineLocalizationBundle)))
            } catch AudioExtractionError.invalidCache {
                onProgress(.cacheInvalidated(reason: String(localized: "音频缓存与媒体不符或不完整，重新提取。", bundle: voxlineLocalizationBundle)))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                onProgress(.cacheInvalidated(reason: String(localized: "音频缓存文件缺失，重新提取。", bundle: voxlineLocalizationBundle)))
            }
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = sourceRange
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioExtractionError.cannotDecode }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioExtractionError.cannotDecode }
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000),
              let destination = buffer.floatChannelData?[0] else { throw AudioExtractionError.invalidPCM }
        var writer: AVAudioFile?
        var chunkStart: Int64 = 0
        var chunkFrames: Int64 = 0
        var expectedFrame: Int64?
        var records: [AudioExtractionRecord.Chunk] = []
        // Finalizing is shared by size boundaries, source gaps, and the final packet.
        func finishChunk() {
            guard chunkFrames > 0 else { return }
            writer = nil
            records.append(.init(sourceStartFrame: chunkStart, frameCount: chunkFrames))
            chunkFrames = 0
        }
        onProgress(.extracting(fraction: 0))
        let clock = ContinuousClock()
        var nextProgressUpdate = clock.now + .milliseconds(200)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = CMSampleBufferGetNumSamples(sample)
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard frames > 0, time.isNumeric, time.seconds >= 0,
                  let description = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  asbd.pointee.mFormatID == kAudioFormatLinearPCM, asbd.pointee.mSampleRate == 16_000,
                  asbd.pointee.mChannelsPerFrame == 1, asbd.pointee.mBitsPerChannel == 32,
                  asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  let block = CMSampleBufferGetDataBuffer(sample),
                  CMBlockBufferGetDataLength(block) == frames * MemoryLayout<Float>.size else {
                throw AudioExtractionError.invalidPCM
            }
            let presentation = CMTimeConvertScale(time, timescale: Self.sampleRate, method: .roundHalfAwayFromZero).value
            if let expectedFrame {
                guard presentation >= expectedFrame - 1 else { throw AudioExtractionError.backwardTimeline }
                // A source gap starts another chunk; it is never removed from absolute time.
                if presentation > expectedFrame + 1 { finishChunk() }
            }
            let packetStart: Int64
            if let expectedFrame, abs(presentation - expectedFrame) <= 1 { packetStart = expectedFrame }
            else { packetStart = presentation }
            let playableFrames = min(frames, Int(max(0, sourceEndFrame - packetStart)))
            var offset = 0
            while offset < playableFrames {
                try Task.checkCancellation()
                if writer == nil {
                    chunkStart = packetStart + Int64(offset)
                    writer = try AVAudioFile(forWriting: Self.chunkURL(in: root, index: records.count),
                                             settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                }
                let count = min(playableFrames - offset, Int(Self.maximumChunkFrames - chunkFrames), Int(buffer.frameCapacity))
                guard CMBlockBufferCopyDataBytes(block, atOffset: offset * MemoryLayout<Float>.size,
                    dataLength: count * MemoryLayout<Float>.size, destination: destination) == kCMBlockBufferNoErr else {
                    throw AudioExtractionError.invalidPCM
                }
                buffer.frameLength = AVAudioFrameCount(count)
                guard let writer else { throw AudioExtractionError.invalidPCM }
                try writer.write(from: buffer)
                offset += count
                chunkFrames += Int64(count)
                if chunkFrames == Self.maximumChunkFrames { finishChunk() }
            }
            expectedFrame = packetStart + Int64(playableFrames)
            let sourceEndMilliseconds = Double(packetStart + Int64(playableFrames)) / 16
            guard sourceEndMilliseconds <= Double(identity.durationMilliseconds) + 1 else {
                throw AudioExtractionError.outsideMedia
            }
            let now = clock.now
            if now >= nextProgressUpdate {
                onProgress(.extracting(fraction: min(sourceEndMilliseconds / Double(identity.durationMilliseconds), 1)))
                nextProgressUpdate = now + .milliseconds(200)
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? AudioExtractionError.incompleteDecode }
        finishChunk()
        guard !records.isEmpty else { throw AudioExtractionError.emptyAudio }
        sourceURL.removeAllCachedResourceValues()
        let after = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw MediaAccessError.fileChanged
        }
        let record = AudioExtractionRecord(formatVersion: 1, identity: identity, chunks: records)
        try Task.checkCancellation()
        let result = try record.audio(in: root, reusedCache: false)
        try JSONEncoder().encode(record).write(to: manifestURL, options: .atomic)
        onProgress(.extracting(fraction: 1))
        return result
    }

    fileprivate static func chunkURL(in directory: URL, index: Int) -> URL {
        directory.appendingPathComponent(String(format: "%06d.wav", index))
    }
}

private struct AudioExtractionRecord: Codable {
    let formatVersion: Int
    let identity: MediaIdentity
    let chunks: [Chunk]
    struct Chunk: Codable { let sourceStartFrame: Int64; let frameCount: Int64 }

    func audio(in directory: URL, reusedCache: Bool) throws -> ExtractedAudio {
        let audio = try chunks.enumerated().map { index, chunk in
            try TranscriptionAudio(localURL: AudioExtractor.chunkURL(in: directory, index: index),
                sourceStartMilliseconds: chunk.sourceStartFrame / 16,
                // Cover fractional milliseconds so a final PCM frame cannot become zero duration.
                durationMilliseconds: chunk.frameCount / 16 + (chunk.frameCount % 16 == 0 ? 0 : 1))
        }
        return ExtractedAudio(chunks: audio, reusedCache: reusedCache)
    }
}

public enum AudioExtractionError: Error, LocalizedError, Equatable {
    case invalidCache, cannotDecode, invalidPCM, backwardTimeline, outsideMedia, incompleteDecode, emptyAudio
    public var errorDescription: String? {
        switch self {
        case .invalidCache: String(localized: "音频缓存不完整或与媒体不符。", bundle: voxlineLocalizationBundle)
        case .cannotDecode: String(localized: "无法将所选音轨解码为转写音频。", bundle: voxlineLocalizationBundle)
        case .invalidPCM: String(localized: "解码输出不是有效的 16 kHz 单声道 Float32 PCM。", bundle: voxlineLocalizationBundle)
        case .backwardTimeline: String(localized: "音轨时间发生回退，提取已停止。", bundle: voxlineLocalizationBundle)
        case .outsideMedia: String(localized: "提取音频的时间超出源媒体范围。", bundle: voxlineLocalizationBundle)
        case .incompleteDecode: String(localized: "音轨解码未完整结束，未提交缓存。", bundle: voxlineLocalizationBundle)
        case .emptyAudio: String(localized: "所选音轨没有可处理的音频。", bundle: voxlineLocalizationBundle)
        }
    }
}
