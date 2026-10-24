#if os(macOS)
import AVKit
import SwiftUI

/// The AppKit player surface keeps macOS 15 playback independent of _AVKit_SwiftUI metadata.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    let pausedFrame: CGImage?

    func makeNSView(context: Context) -> PausedFramePlayerView {
        let view = PausedFramePlayerView()
        view.controlsStyle = .none
        // Proofreading seeks while paused; Live Text retains a separately analysed frame.
        view.allowsVideoFrameAnalysis = false
        view.player = player
        view.pausedFrame = pausedFrame
        return view
    }

    func updateNSView(_ view: PausedFramePlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.pausedFrame = pausedFrame
    }

    static func dismantleNSView(_ view: PausedFramePlayerView, coordinator: ()) {
        view.pausedFrame = nil
        view.player = nil
    }
}

final class PausedFramePlayerView: AVPlayerView {
    private let stillLayer = CALayer()

    var pausedFrame: CGImage? {
        didSet {
            guard pausedFrame !== oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stillLayer.contents = pausedFrame
            stillLayer.isHidden = pausedFrame == nil
            CATransaction.commit()
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stillLayer.contentsGravity = .resize
        stillLayer.isHidden = true
        if let overlay = contentOverlayView {
            overlay.wantsLayer = true
            overlay.layer?.addSublayer(stillLayer)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard let overlay = contentOverlayView else { return }
        // AVKit owns the display aspect ratio, including pixel aspect and letterboxing.
        // Bitmap dimensions must not drive a second, independent video layout.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillLayer.frame = overlay.convert(videoBounds, from: self)
        CATransaction.commit()
    }
}

#endif
