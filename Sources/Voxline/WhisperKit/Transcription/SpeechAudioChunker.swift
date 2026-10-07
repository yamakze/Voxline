import AVFoundation
import Foundation
import VoxlineCore
import WhisperKit

/// Reuses the pinned SDK's energy VAD; coarse ranges remain distinct from word alignment.
public enum SpeechAudioChunker {
    public static func chunks(from audio: TranscriptionAudio) throws -> [TranscriptionAudio] {
        try Task.checkCancellation()
        let source = try AVAudioFile(forReading: audio.localURL)
        guard source.processingFormat.sampleRate == 16_000, source.processingFormat.channelCount == 1,
              source.length > 0, source.length <= 120 * 16_000,
              (source.length + 15) / 16 == audio.durationMilliseconds,
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)) else {
            throw WhisperTranscriptionError.invalidAudio
        }
        try source.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else { throw WhisperTranscriptionError.invalidAudio }
        let waveform = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        guard waveform.allSatisfy(\.isFinite) else { throw WhisperTranscriptionError.invalidAudio }
        let detected = EnergyVAD(sampleRate: 16_000, frameLength: 0.02, energyThreshold: 0.02)
            .calculateActiveChunks(in: waveform)
        // Pad speech by 200 ms and join short pauses; never compress the original timeline.
        var ranges: [Range<Int>] = []
        for region in detected {
            let start = max(0, region.startIndex - 3200)
            let end = min(waveform.count, region.endIndex + 3200)
            if let last = ranges.last, start <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else { ranges.append(start..<end) }
        }
        if ranges.isEmpty {
            // A silence-only extraction still has a checkpoint; it makes no paid request.
            return [try TranscriptionAudio(localURL: audio.localURL, sourceStartMilliseconds: audio.sourceStartMilliseconds,
                durationMilliseconds: audio.durationMilliseconds, isSilent: true)]
        }
        let directory = audio.localURL.deletingLastPathComponent().appendingPathComponent("speech", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result: [TranscriptionAudio] = []
        for range in ranges {
            var start = range.lowerBound
            while start < range.upperBound {
                try Task.checkCancellation()
                let end = min(start + 8 * 16_000, range.upperBound)
                let url = directory.appendingPathComponent("\(audio.localURL.deletingPathExtension().lastPathComponent)-\(start)-\(end).wav")
                if FileManager.default.fileExists(atPath: url.path) {
                    let cached = try AVAudioFile(forReading: url)
                    guard cached.length == end - start, cached.fileFormat.sampleRate == 16_000,
                          cached.fileFormat.channelCount == 1, cached.fileFormat.commonFormat == .pcmFormatInt16 else {
                        throw WhisperTranscriptionError.invalidAudio
                    }
                } else {
                    guard let slice = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(end - start)),
                          let destination = slice.floatChannelData?[0] else { throw WhisperTranscriptionError.invalidAudio }
                    slice.frameLength = slice.frameCapacity
                    destination.update(from: samples.advanced(by: start), count: end - start)
                    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
                    let temporary = directory.appendingPathComponent("\(UUID()).partial.wav")
                    do {
                        // Close the writer before publication so file length and header are complete.
                        do {
                            let writer = try AVAudioFile(forWriting: temporary, settings: settings)
                            try writer.write(from: slice)
                        }
                        try Task.checkCancellation()
                        try FileManager.default.moveItem(at: temporary, to: url)
                    } catch {
                        let cause = error
                        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
                        throw cause
                    }
                }
                let sourceStart = audio.sourceStartMilliseconds + Int64(start / 16)
                let sourceEnd = audio.sourceStartMilliseconds + Int64((end + 15) / 16)
                result.append(try .init(localURL: url, sourceStartMilliseconds: sourceStart,
                    durationMilliseconds: sourceEnd - sourceStart))
                start = end
            }
        }
        return result
    }
}
