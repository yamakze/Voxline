import AVFoundation
import Foundation
import Testing
import VoxlineCore
@testable import VoxlineMedia

@Suite("Native movie inspection")
struct MediaInspectionTests {
    @Test func multipleLanguageTracksKeepExplicitIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MovieFixture.make(in: directory, audioLanguages: ["eng", "spa"])
        let result = try await MediaInspector().inspect(url)
        #expect(result.videoTracks.count == 1)
        #expect(result.audioTracks.count == 2)
        #expect(Set(result.audioTracks.compactMap(\.language)) == ["en", "es"] ||
                Set(result.audioTracks.compactMap(\.language)) == ["eng", "spa"])
        #expect(result.audioTracks.allSatisfy { $0.isDecodable })
        #expect(result.durationMilliseconds == 1000)
        let selected = try #require(result.audioTracks.last)
        #expect(try result.identity(audioTrackID: selected.id).audioTrackID == selected.id)
        #expect(throws: MediaAccessError.invalidAudioTrack) { try result.identity(audioTrackID: 9999) }
        let again = try await MediaInspector().inspect(url)
        #expect(again.sha256 == result.sha256)
        #expect(again.byteCount == result.byteCount)
    }

    @Test func videoWithoutAudioHasAnExplicitFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MovieFixture.make(in: directory, audioLanguages: [])
        await #expect(throws: MediaAccessError.noAudio) { try await MediaInspector().inspect(url) }
    }
}

enum MovieFixture {
    static func make(in directory: URL, audioLanguages: [String]) async throws -> URL {
        let url = directory.appendingPathComponent("sample.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                       AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                          sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                                       kCVPixelBufferWidthKey as String: 32,
                                                                                       kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        var description: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        try #require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                   layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        let format = try #require(description)
        var audioInputs: [AVAssetWriterInput] = []
        for language in audioLanguages {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            audio.languageCode = language
            writer.add(audio)
            audioInputs.append(audio)
        }
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0, CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        try #require(input.isReadyForMoreMediaData)
        try #require(adaptor.append(pixelBuffer, withPresentationTime: .zero))
        var block: CMBlockBuffer?
        try #require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                       blockLength: 32000, blockAllocator: kCFAllocatorDefault,
                                                       customBlockSource: nil, offsetToData: 0, dataLength: 32000,
                                                       flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr)
        let pcm = try #require(block)
        try #require(CMBlockBufferFillDataBytes(with: 0, blockBuffer: pcm, offsetIntoDestination: 0, dataLength: 32000) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sample: CMSampleBuffer?
        try #require(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: pcm,
                                               formatDescription: format, sampleCount: 16000,
                                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                               sampleBufferOut: &sample) == noErr)
        let audioSample = try #require(sample)
        for audio in audioInputs {
            try #require(audio.isReadyForMoreMediaData)
            try #require(audio.append(audioSample))
            audio.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }
}
