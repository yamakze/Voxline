import AVFoundation
import Foundation
import VoxlineCore

/// Slice bounded PCM input around already committed recognition intervals.
public enum TranscriptionAudioSlicer {
    public static func slice(_ audio: TranscriptionAudio, range: TranscriptionChunkRange) throws -> TranscriptionAudio {
        try Task.checkCancellation()
        let offset = range.sourceStartMilliseconds - audio.sourceStartMilliseconds
        guard offset >= 0, range.durationMilliseconds > 0,
              offset + range.durationMilliseconds <= audio.durationMilliseconds else { throw AudioExtractionError.outsideMedia }
        if offset == 0, range.durationMilliseconds == audio.durationMilliseconds { return audio }

        let source = try AVAudioFile(forReading: audio.localURL)
        guard source.processingFormat.sampleRate == 16_000, source.processingFormat.channelCount == 1 else {
            throw AudioExtractionError.invalidPCM
        }
        let start = offset * 16
        // The final declared millisecond may contain fewer than 16 PCM frames.
        let end = min(source.length, (offset + range.durationMilliseconds) * 16)
        guard start < end,
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_000) else {
            throw AudioExtractionError.invalidPCM
        }
        source.framePosition = start
        let directory = audio.localURL.deletingLastPathComponent().appendingPathComponent("slices", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(audio.localURL.deletingPathExtension().lastPathComponent)-\(offset)-\(range.durationMilliseconds).wav")
        do {
            // The writer closes before another provider reads the complete WAV header.
            try autoreleasepool {
                let writer = try AVAudioFile(forWriting: url, settings: source.fileFormat.settings,
                                            commonFormat: source.processingFormat.commonFormat, interleaved: source.processingFormat.isInterleaved)
                var remaining = end - start
                while remaining > 0 {
                    try Task.checkCancellation()
                    try source.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, Int64(buffer.frameCapacity))))
                    guard buffer.frameLength > 0 else { throw AudioExtractionError.invalidPCM }
                    try writer.write(from: buffer)
                    remaining -= Int64(buffer.frameLength)
                }
            }
            try Task.checkCancellation()
            return try TranscriptionAudio(localURL: url, sourceStartMilliseconds: range.sourceStartMilliseconds,
                durationMilliseconds: range.durationMilliseconds, isSilent: audio.isSilent)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}
