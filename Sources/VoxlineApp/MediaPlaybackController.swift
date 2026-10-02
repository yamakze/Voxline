import AVFoundation
import Foundation
import Observation
import VoxlineCore
import VoxlineMedia

@Observable
@MainActor
public final class MediaPlaybackController {
    public var player: AVPlayer?
    public var isReady = false
    public var isLoading = false
    public var isPlaying = false
    public var isMediaUnavailable = false
    public var errorMessage: String?
    public var currentTimeSeconds: Double = 0.0
    public var durationSeconds: Double = 0.0
    public var playbackRate: Float = 1.0

    private var timeObserver: Any?
    private var mediaURL: URL?
    private var mediaAccessStarted = false

    public init() {}

    public var formattedCurrentTime: String {
        let total = Int(currentTimeSeconds)
        let m = total / 60
        let s = total % 60
        let ms = Int((currentTimeSeconds.truncatingRemainder(dividingBy: 1.0)) * 1000)
        return String(format: "%02d:%02d.%03d", m, s, ms)
    }

    public var formattedDuration: String {
        let total = Int(durationSeconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    public func loadMedia(for item: TaskMediaItem) async {
        releaseMedia()
        guard let identity = item.media else {
            isMediaUnavailable = true
            errorMessage = "尚未关联本地媒体文件。"
            return
        }

        isLoading = true
        errorMessage = nil
        isMediaUnavailable = false
        defer { isLoading = false }

        do {
            guard let bookmark = try await LocalMediaStore.shared.resolve(projectID: item.id, identity: identity) else {
                isMediaUnavailable = true
                errorMessage = "本地原文件未找到，请重新关联媒体。"
                return
            }
            let accessStarted = bookmark.url.startAccessingSecurityScopedResource()
            var retainsAccess = false
            defer { if accessStarted && !retainsAccess { bookmark.url.stopAccessingSecurityScopedResource() } }
            let inspection = try await MediaInspector.shared.inspect(bookmark.url)
            let current = try inspection.identity(audioTrackID: identity.audioTrackID)
            guard identity.matchesContent(of: current) else { throw ProjectValidationError.differentMedia }
            if bookmark.isStale {
                try await LocalMediaStore.shared.save(projectID: item.id, identity: identity, url: bookmark.url)
            }
            let asset = AVURLAsset(url: bookmark.url)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audio = audioTracks.first(where: { $0.trackID == identity.audioTrackID }) else {
                throw MediaAccessError.invalidAudioTrack
            }
            // Preview exactly the chosen audio track, preserving each source track's start time.
            let composition = AVMutableComposition()
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            for track in Array(videoTracks.prefix(1)) + [audio] {
                guard let output = composition.addMutableTrack(withMediaType: track.mediaType,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw MediaAccessError.invalidAudioTrack
                }
                let range = try await track.load(.timeRange)
                try output.insertTimeRange(range, of: track, at: range.start)
                if track.mediaType == .video {
                    output.preferredTransform = try await track.load(.preferredTransform)
                }
            }
            try Task.checkCancellation()
            durationSeconds = Double(inspection.durationMilliseconds) / 1000.0
            let playerItem = AVPlayerItem(asset: composition)
            let newPlayer = AVPlayer(playerItem: playerItem)

            if let observer = timeObserver {
                player?.removeTimeObserver(observer)
            }

            let interval = CMTime(value: 1, timescale: 30) // ~30fps
            timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    self?.currentTimeSeconds = time.seconds
                }
            }

            self.player = newPlayer
            mediaURL = bookmark.url
            mediaAccessStarted = accessStarted
            retainsAccess = true
            self.isReady = true
        } catch is CancellationError {
            return
        } catch {
            isMediaUnavailable = true
            errorMessage = error.localizedDescription
        }
    }

    public func releaseMedia() {
        player?.pause()
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        player = nil
        if mediaAccessStarted { mediaURL?.stopAccessingSecurityScopedResource() }
        mediaURL = nil
        mediaAccessStarted = false
        isReady = false
        isPlaying = false
        currentTimeSeconds = 0
        durationSeconds = 0
    }

    public func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        }
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, min(seconds, durationSeconds))
        currentTimeSeconds = clamped
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func seek(toMilliseconds ms: Int64) {
        seek(to: Double(ms) / 1000.0)
    }

    public func seekRelative(by delta: Double) {
        seek(to: currentTimeSeconds + delta)
    }

    public func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    public func isCueActive(_ cue: SubtitleCue) -> Bool {
        let currentMs = Int64(currentTimeSeconds * 1000.0)
        return cue.startMilliseconds <= currentMs && currentMs <= cue.endMilliseconds
    }

    public func activeCue(in cues: [SubtitleCue]) -> SubtitleCue? {
        let currentMs = Int64(currentTimeSeconds * 1000.0)
        return cues.first { $0.startMilliseconds <= currentMs && currentMs <= $0.endMilliseconds }
    }
}
