import AVFoundation
import Foundation
import Observation
import OSLog
import VoxlineCore

@Observable
@MainActor
public final class MediaPlaybackController {
    public struct SourceIdentity: Equatable, Sendable {
        public let itemID: UUID
        public let media: MediaIdentity?
        public init(item: TaskMediaItem) { itemID = item.id; media = item.media }
    }

    public struct LoadRequest: Equatable, Sendable {
        public let source: SourceIdentity
        public let localAssociationRevision: Int

        public init(source: SourceIdentity, localAssociationRevision: Int) {
            self.source = source
            self.localAssociationRevision = localAssociationRevision
        }
    }

    public private(set) var player: AVPlayer?
    public private(set) var isReady = false
    public private(set) var isLoading = false
    public private(set) var isPlaying = false
    public private(set) var isMediaUnavailable = false
    public private(set) var errorMessage: String?
    public private(set) var currentTimeSeconds: Double = 0
    public private(set) var progressTimeSeconds: Double = 0
    public private(set) var elapsedWholeSeconds = 0
    public private(set) var durationSeconds: Double = 0
    public private(set) var playbackRate: Float = 1
    public private(set) var volume: Float = 1.0
    public private(set) var isMuted: Bool = false
    public var activeSubtitle: SubtitleCue? { activeSubtitles.last }
    public private(set) var activeSubtitles: [SubtitleCue] = []
    public private(set) var completedSubtitleEndMilliseconds: Int64 = 0

    @ObservationIgnored private var subtitles: [SubtitleCue] = []
    @ObservationIgnored private var subtitleTimeline = SubtitleTimeline(cues: [])
    @ObservationIgnored private var subtitleEndTimes: [Int64] = []
    @ObservationIgnored private var activeCueIndices: [Int]?
    @ObservationIgnored private var previousVolume: Float = 1.0

    private let mediaStore: LocalMediaStore
    private let inspector: MediaInspector
    private var generation = UUID()
    private var seekID = UUID()
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var nextProgressUpdate = ContinuousClock.now
    private var playbackIntentID = UUID()
    private var timeObserver: Any?
    private var itemObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var mediaURL: URL?
    private var mediaAccessStarted = false
    #if os(macOS)
    public private(set) var pausedVideoFrame: PausedVideoFrame?
    @ObservationIgnored private var pausedFrameSource: PausedVideoFrameSource?
    @ObservationIgnored private var pausedFrameTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "dev.voxline.app", category: "PausedVideoFrame")
    #endif

    public init(mediaStore: LocalMediaStore = .shared, inspector: MediaInspector = .shared) {
        self.mediaStore = mediaStore
        self.inspector = inspector
    }

    #if os(macOS)
    isolated deinit { pausedFrameTask?.cancel() }
    #endif

    public var formattedCurrentTime: String {
        TimecodeFormatter.formatDuration(seconds: Double(elapsedWholeSeconds))
    }

    public var formattedDuration: String {
        TimecodeFormatter.formatDuration(seconds: durationSeconds)
    }

    public func loadMedia(for item: TaskMediaItem) async {
        releaseMedia()
        updateSubtitles(item.cues)
        let loadID = generation
        guard let identity = item.media else {
            isMediaUnavailable = true
            errorMessage = String(localized: "尚未关联本地媒体文件。", bundle: voxlineLocalizationBundle)
            return
        }
        isLoading = true
        do {
            guard let bookmark = try await mediaStore.resolve(mediaID: item.id, identity: identity) else {
                guard generation == loadID else { return }
                isLoading = false
                isMediaUnavailable = true
                errorMessage = String(localized: "本地原文件未找到，请重新关联媒体。", bundle: voxlineLocalizationBundle)
                return
            }
            guard generation == loadID else { return }
            let accessStarted = bookmark.url.startAccessingSecurityScopedResource()
            var retainsAccess = false
            defer { if accessStarted && !retainsAccess { bookmark.url.stopAccessingSecurityScopedResource() } }
            let inspection = try await inspector.inspect(bookmark.url)
            if item.kind == .video { try inspection.requireDecodableVideo() }
            let current = try inspection.identity(audioTrackID: identity.audioTrackID)
            guard identity.matchesContent(of: current) else { throw DomainValidationError.differentMedia }
            if bookmark.isStale {
                try await mediaStore.save(mediaID: item.id, identity: identity, url: bookmark.url)
            }
            let asset = AVURLAsset(url: bookmark.url)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audio = audioTracks.first(where: { $0.trackID == identity.audioTrackID }) else {
                throw MediaAccessError.invalidAudioTrack
            }
            // One selected audio track; source starts and video transforms share the subtitle timeline.
            let composition = AVMutableComposition()
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            #if os(macOS)
            var frameSource: PausedVideoFrameSource?
            #endif
            for track in Array(videoTracks.prefix(1)) + [audio] {
                guard let output = composition.addMutableTrack(withMediaType: track.mediaType,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw MediaAccessError.invalidAudioTrack
                }
                let range = try await track.load(.timeRange)
                try output.insertTimeRange(range, of: track, at: range.start)
                if track.mediaType == .video {
                    let transform = try await track.load(.preferredTransform)
                    output.preferredTransform = transform
                    #if os(macOS)
                    frameSource = PausedVideoFrameSource(url: bookmark.url, trackID: track.trackID, transform: transform)
                    #endif
                }
            }
            try Task.checkCancellation()
            guard generation == loadID else { return }
            #if os(macOS)
            pausedFrameSource = frameSource
            #endif
            durationSeconds = Double(inspection.durationMilliseconds) / 1000
            let playerItem = AVPlayerItem(asset: composition)
            let newPlayer = AVPlayer(playerItem: playerItem)
            newPlayer.volume = isMuted ? 0 : volume
            newPlayer.isMuted = isMuted
            player = newPlayer
            mediaURL = bookmark.url
            mediaAccessStarted = accessStarted
            retainsAccess = true

            itemObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status.rawValue
                let reason = item.error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == loadID else { return }
                    switch AVPlayerItem.Status(rawValue: status) {
                    case .readyToPlay:
                        self.isReady = true
                        self.isLoading = false
                    case .failed:
                        self.isReady = false
                        self.isLoading = false
                        self.isPlaying = false
                        self.isMediaUnavailable = true
                        self.errorMessage = reason ?? String(localized: "系统播放器无法播放此媒体。", bundle: voxlineLocalizationBundle)
                    default: break
                    }
                }
            }
            playbackObservation = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == loadID else { return }
                    self.isPlaying = player.timeControlStatus != .paused && self.isReady
                    #if os(macOS)
                    if player.timeControlStatus != .paused {
                        self.pausedFrameTask?.cancel()
                        self.pausedFrameTask = nil
                        self.pausedVideoFrame = nil
                    }
                    #endif
                }
            }
            timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == loadID, !self.isSeeking,
                          let seconds = self.player?.currentTime().seconds, seconds.isFinite else { return }
                    // A queued observer callback can outlive a seek; read the current native clock.
                    self.updatePlaybackTime(max(0, min(seconds, self.durationSeconds)))
                }
            }
            notificationObservers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == loadID else { return }
                    self.isPlaying = false
                    self.updatePlaybackTime(self.durationSeconds, immediateProgress: true)
                }
            })
            notificationObservers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main
            ) { [weak self] notification in
                let reason = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == loadID else { return }
                    self.player?.pause()
                    self.isReady = false
                    self.isPlaying = false
                    self.isLoading = false
                    self.isMediaUnavailable = true
                    self.errorMessage = reason ?? String(localized: "媒体播放中断，未播放到结束。", bundle: voxlineLocalizationBundle)
                }
            })
        } catch {
            guard generation == loadID else { return }
            isLoading = false
            if error is CancellationError { return }
            isMediaUnavailable = true
            errorMessage = error.localizedDescription
        }
    }

    public func releaseMedia() {
        generation = UUID()
        seekID = UUID()
        isSeeking = false
        #if os(macOS)
        pausedFrameTask?.cancel()
        pausedFrameTask = nil
        pausedFrameSource = nil
        pausedVideoFrame = nil
        #endif
        itemObservation?.invalidate()
        playbackObservation?.invalidate()
        itemObservation = nil
        playbackObservation = nil
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        notificationObservers = []
        player?.pause()
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        player = nil
        if mediaAccessStarted { mediaURL?.stopAccessingSecurityScopedResource() }
        mediaURL = nil
        mediaAccessStarted = false
        isReady = false
        isLoading = false
        isPlaying = false
        isMediaUnavailable = false
        errorMessage = nil
        currentTimeSeconds = 0
        progressTimeSeconds = 0
        elapsedWholeSeconds = 0
        nextProgressUpdate = .now
        subtitles = []
        activeSubtitles = []
        activeCueIndices = nil
        subtitleTimeline = SubtitleTimeline(cues: [])
        subtitleEndTimes = []
        completedSubtitleEndMilliseconds = 0
        durationSeconds = 0
        playbackRate = 1
    }

    public func togglePlayPause() {
        guard isReady, let player else { return }
        if player.timeControlStatus != .paused { pause() }
        else if currentTimeSeconds >= durationSeconds { seek(to: 0, resumePlayback: true) }
        else if isSeeking { seek(to: currentTimeSeconds, resumePlayback: true) }
        else { player.playImmediately(atRate: playbackRate) }
    }

    public func pause() {
        playbackIntentID = UUID()
        player?.pause()
        if isSeeking { seek(to: currentTimeSeconds) }
    }

    public func seek(to seconds: Double, resumePlayback: Bool = false, isScrubbing: Bool = false) {
        guard isReady, let player, seconds.isFinite else { return }
        let clamped = max(0, min(seconds, durationSeconds))
        let loadID = generation
        let requestID = UUID()
        let resumeIntentID = playbackIntentID
        seekID = requestID
        isSeeking = true
        // Keep controls and subtitle focus on the requested position until native seeking settles.
        // Periodic callbacks may still carry the previous position during this interval.
        updatePlaybackTime(clamped, immediateProgress: true)
        #if os(macOS)
        pausedFrameTask?.cancel()
        pausedFrameTask = nil
        #endif
        let tolerance = isScrubbing ? CMTime(seconds: 0.25, preferredTimescale: 600) : .zero
        let time = CMTime(seconds: clamped, preferredTimescale: 60_000)
        let completion: @Sendable (Bool) -> Void = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == loadID, self.seekID == requestID else { return }
                self.isSeeking = false
                let actual = self.player?.currentTime().seconds
                if let actual, actual.isFinite {
                    self.updatePlaybackTime(max(0, min(actual, self.durationSeconds)), immediateProgress: true)
                }
                guard finished else { return }
                if resumePlayback, self.playbackIntentID == resumeIntentID, self.isReady {
                    self.player?.playImmediately(atRate: self.playbackRate)
                }
            }
        }
        #if os(macOS)
        if !isScrubbing, !resumePlayback, player.timeControlStatus == .paused, let source = pausedFrameSource {
            // Stop coarse seeks before preparing the final still. Native exact seeking must not
            // expose interframe decoding while the paused-frame layer is being prepared.
            player.currentItem?.cancelPendingSeeks()
            pausedFrameTask = Task { [weak self] in
                let frame: PausedVideoFrame?
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    frame = try await source.frame(at: time)
                } catch is CancellationError { return }
                catch {
                    // The native player remains the explicit fallback for optional still decoding.
                    Self.logger.error("Paused video frame unavailable: \(error.localizedDescription)")
                    frame = nil
                }
                guard !Task.isCancelled, let self, self.generation == loadID, self.seekID == requestID,
                      player.timeControlStatus == .paused else { return }
                self.pausedVideoFrame = frame
                // Give the paused-frame view the new image before native synchronization starts.
                await Task.yield()
                guard !Task.isCancelled, self.generation == loadID, self.seekID == requestID else { return }
                self.pausedFrameTask = nil
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: completion)
            }
            return
        }
        pausedVideoFrame = nil
        #endif
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance, completionHandler: completion)
    }

    public func seek(toMilliseconds ms: Int64) { seek(to: Double(ms) / 1000) }
    public func seekRelative(by delta: Double) { seek(to: currentTimeSeconds + delta) }

    public func setRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        playbackRate = rate
        if let player, player.timeControlStatus != .paused { player.rate = rate }
    }

    public func setVolume(_ value: Float) {
        let clamped = max(0.0, min(value, 1.0))
        volume = clamped
        if clamped > 0 {
            previousVolume = clamped
            if isMuted {
                isMuted = false
                player?.isMuted = false
            }
        }
        player?.volume = clamped
    }

    public func toggleMute() {
        if isMuted {
            isMuted = false
            if volume == 0 {
                volume = previousVolume > 0 ? previousVolume : 0.5
            }
            player?.volume = volume
            player?.isMuted = false
        } else {
            previousVolume = volume
            isMuted = true
            player?.isMuted = true
        }
    }

    public func updateSubtitles(_ cues: [SubtitleCue]) {
        subtitles = cues
        subtitleTimeline = SubtitleTimeline(cues: cues)
        subtitleEndTimes = cues.map(\.endMilliseconds).sorted()
        activeCueIndices = nil
        updatePlaybackTime(currentTimeSeconds)
    }

    /// Transport time drives only controls; subtitle consumers observe boundary changes.
    private func updatePlaybackTime(_ seconds: Double, immediateProgress: Bool = false) {
        currentTimeSeconds = seconds
        let now = ContinuousClock.now
        if immediateProgress || now >= nextProgressUpdate {
            progressTimeSeconds = seconds
            nextProgressUpdate = now.advanced(by: .milliseconds(100))
        }
        let wholeSeconds = Int(seconds.rounded(.down))
        if elapsedWholeSeconds != wholeSeconds { elapsedWholeSeconds = wholeSeconds }
        let milliseconds = Int64((seconds * 1000).rounded(.down))
        let indices = subtitleTimeline.interval(atMilliseconds: milliseconds)?.cueIndices ?? []
        if activeCueIndices != indices {
            activeCueIndices = indices
            activeSubtitles = indices.map { subtitles[$0] }
        }
        var lower = 0, upper = subtitleEndTimes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if subtitleEndTimes[middle] <= milliseconds { lower = middle + 1 } else { upper = middle }
        }
        let completedEnd = lower > 0 ? subtitleEndTimes[lower - 1] : 0
        if completedSubtitleEndMilliseconds != completedEnd { completedSubtitleEndMilliseconds = completedEnd }
    }

}
