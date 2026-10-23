#if os(macOS)
import AVFoundation
import CoreImage

public struct PausedVideoFrame: Sendable {
    public let image: CGImage
    public let time: CMTime
}

/// Decode from a sync sample rather than relying on AVPlayer's paused random-access decoder.
actor PausedVideoFrameSource {
    private let asset: AVURLAsset
    private let trackID: CMPersistentTrackID
    private var videoTrack: AVAssetTrack?
    let transform: CGAffineTransform
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init(url: URL, trackID: CMPersistentTrackID, transform: CGAffineTransform) {
        asset = AVURLAsset(url: url)
        self.trackID = trackID
        self.transform = transform
    }

    func frame(at time: CMTime) async throws -> PausedVideoFrame {
        try Task.checkCancellation()
        let track: AVAssetTrack
        if let videoTrack { track = videoTrack }
        else {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let matching = tracks.first(where: { $0.trackID == trackID }) else { throw MediaAccessError.noVideo }
            videoTrack = matching
            track = matching
        }
        try Task.checkCancellation()
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: time) else {
            throw MediaAccessError.undecodableVideo
        }
        let target = cursor.presentationTimeStamp
        while !cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
            try Task.checkCancellation()
            if cursor.stepInDecodeOrder(byCount: -1) == 0 { break }
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        // Read only until the target sample is decoded; no whole-file scan or frame cache.
        reader.timeRange = CMTimeRange(start: cursor.presentationTimeStamp, duration: .positiveInfinity)
        guard reader.startReading() else { throw reader.error ?? MediaAccessError.undecodableVideo }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            guard timestamp >= target, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
            guard let result = Self.context.createCGImage(image, from: image.extent) else {
                throw MediaAccessError.undecodableVideo
            }
            try Task.checkCancellation()
            return PausedVideoFrame(image: result, time: timestamp)
        }
        throw reader.error ?? MediaAccessError.undecodableVideo
    }
}
#endif
