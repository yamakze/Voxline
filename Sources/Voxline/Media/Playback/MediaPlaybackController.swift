import AVFoundation
import Foundation
import Observation
import VoxlineCore

@Observable
@MainActor
public final class MediaPlaybackController {
    public struct SourceIdentity: Equatable, Sendable {
        public let itemID: UUID
        public let media: MediaIdentity?
        public init(item: TaskMediaItem) { itemID = item.id; media = item.media }
    }

    public private(set) var player: AVPlayer?
    public private(set) var isReady = false
    public private(set) var isLoading = false
    public private(set) var isPlaying = false
    public private(set) var isMediaUnavailable = false
    public private(set) var errorMessage: String?
    public private(set) var currentTimeSeconds: Double = 0
    public private(set) var durationSeconds: Double = 0
    public private(set) var playbackRate: Float = 1
    public private(set) var activeSubtitle: SubtitleCue?
    public private(set) var activeSubtitles: [SubtitleCue] = []
    public private(set) var completedSubtitleEndMilliseconds: Int64 = 0

    @ObservationIgnored private var subtitles: [SubtitleCue] = []
    @ObservationIgnored private var subtitleTimeline = SubtitleTimeline(cues: [])
    @ObservationIgnored private var subtitleEndTimes: [Int64] = []

    private let mediaStore: LocalMediaStore
    private let inspector: MediaInspector
    private var generation = UUID()
    private var seekID = UUID()
    private var timeObserver: Any?
    private var itemObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var mediaURL: URL?
    private var mediaAccessStarted = false

    public init(mediaStore: LocalMediaStore = .shared, inspector: MediaInspector = .shared) {
        self.mediaStore = mediaStore
        self.inspector = inspector
    }

    public var formattedCurrentTime: String {
        let roundedSeconds = (currentTimeSeconds * 1000).rounded() / 1000
        let total = Int(roundedSeconds)
        let milliseconds = Int(((roundedSeconds - Double(total)) * 1000).rounded())
        return String(format: "%02d:%02d.%03d", total / 60, total % 60, milliseconds)
    }

    public var formattedDuration: String {
        let total = Int(durationSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
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
            for track in Array(videoTracks.prefix(1)) + [audio] {
                guard let output = composition.addMutableTrack(withMediaType: track.mediaType,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw MediaAccessError.invalidAudioTrack
                }
                let range = try await track.load(.timeRange)
                try output.insertTimeRange(range, of: track, at: range.start)
                if track.mediaType == .video { output.preferredTransform = try await track.load(.preferredTransform) }
            }
            try Task.checkCancellation()
            guard generation == loadID else { return }
            durationSeconds = Double(inspection.durationMilliseconds) / 1000
            let playerItem = AVPlayerItem(asset: composition)
            let newPlayer = AVPlayer(playerItem: playerItem)
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
                }
            }
            timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                let seconds = time.seconds
                MainActor.assumeIsolated {
                    guard let self, self.generation == loadID, seconds.isFinite else { return }
                    self.updatePlaybackTime(max(0, min(seconds, self.durationSeconds)))
                }
            }
            notificationObservers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == loadID else { return }
                    self.isPlaying = false
                    self.updatePlaybackTime(self.durationSeconds)
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
        subtitles = []
        activeSubtitle = nil
        activeSubtitles = []
        subtitleTimeline = SubtitleTimeline(cues: [])
        subtitleEndTimes = []
        completedSubtitleEndMilliseconds = 0
        durationSeconds = 0
        playbackRate = 1
    }

    public func togglePlayPause() {
        guard isReady, let player else { return }
        if player.timeControlStatus != .paused { player.pause() }
        else if currentTimeSeconds >= durationSeconds { seek(to: 0, resumePlayback: true) }
        else { player.playImmediately(atRate: playbackRate) }
    }

    public func pause() { player?.pause() }

    public func seek(to seconds: Double, resumePlayback: Bool = false) {
        guard isReady, let player, seconds.isFinite else { return }
        let clamped = max(0, min(seconds, durationSeconds))
        let loadID = generation
        let requestID = UUID()
        seekID = requestID
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard finished, let self, self.generation == loadID, self.seekID == requestID else { return }
                let actual = self.player?.currentTime().seconds
                if let actual, actual.isFinite { self.updatePlaybackTime(max(0, min(actual, self.durationSeconds))) }
                if resumePlayback, self.isReady { self.player?.playImmediately(atRate: self.playbackRate) }
            }
        }
    }

    public func seek(toMilliseconds ms: Int64) { seek(to: Double(ms) / 1000) }
    public func seekRelative(by delta: Double) { seek(to: currentTimeSeconds + delta) }

    public func setRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        playbackRate = rate
        if let player, player.timeControlStatus != .paused { player.rate = rate }
    }

    public func updateSubtitles(_ cues: [SubtitleCue]) {
        subtitles = cues
        subtitleTimeline = SubtitleTimeline(cues: cues)
        subtitleEndTimes = cues.map(\.endMilliseconds).sorted()
        updatePlaybackTime(currentTimeSeconds)
    }

    /// Transport time drives only controls; subtitle consumers observe boundary changes.
    private func updatePlaybackTime(_ seconds: Double) {
        currentTimeSeconds = seconds
        let milliseconds = Int64((seconds * 1000).rounded(.down))
        let active = subtitleTimeline.interval(atMilliseconds: milliseconds)?.cueIndices.map { subtitles[$0] } ?? []
        var lower = 0, upper = subtitleEndTimes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if subtitleEndTimes[middle] <= milliseconds { lower = middle + 1 } else { upper = middle }
        }
        let completedEnd = lower > 0 ? subtitleEndTimes[lower - 1] : 0
        if activeSubtitles != active { activeSubtitles = active }
        if activeSubtitle != active.last { activeSubtitle = active.last }
        if completedSubtitleEndMilliseconds != completedEnd { completedSubtitleEndMilliseconds = completedEnd }
    }

}
