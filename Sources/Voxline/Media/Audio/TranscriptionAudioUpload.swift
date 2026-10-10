import AVFoundation
import Foundation
import VoxlineCore

public enum TranscriptionAudioUpload {
    /// Transport-only silence preserves the source range and original PCM file.
    public static func paddedToOneSecond(_ audio: TranscriptionAudio) throws -> Data {
        let file = try AVAudioFile(forReading: audio.localURL, commonFormat: .pcmFormatInt16, interleaved: true)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length > 0, file.length < 16_000, (file.length + 15) / 16 == audio.durationMilliseconds,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TranscriptionInputError.invalidAudio
        }
        try file.read(into: buffer)
        guard Int64(buffer.frameLength) == file.length, let samples = buffer.int16ChannelData?[0] else {
            throw TranscriptionInputError.invalidAudio
        }
        // Canonical little-endian mono PCM16 WAV; only the upload envelope has a 1 s duration.
        var data = Data("RIFF".utf8)
        func appendInteger<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        appendInteger(UInt32(36 + 32_000))
        data.append(Data("WAVEfmt ".utf8))
        appendInteger(UInt32(16))
        appendInteger(UInt16(1))
        appendInteger(UInt16(1))
        appendInteger(UInt32(16_000))
        appendInteger(UInt32(32_000))
        appendInteger(UInt16(2))
        appendInteger(UInt16(16))
        data.append(Data("data".utf8))
        appendInteger(UInt32(32_000))
        data.append(contentsOf: UnsafeRawBufferPointer(start: samples, count: Int(file.length) * 2))
        data.append(Data(count: (16_000 - Int(file.length)) * 2))
        return data
    }

}
