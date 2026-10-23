import SwiftUI
import VoxlineMedia
#if os(macOS)
import AppKit
#endif

struct ProofreadingPlayerControls: View {
    @Bindable var playback: MediaPlaybackController
    var style: Style = .capsule

    enum Style {
        case capsule
        case card
        #if os(macOS)
        case docked
        #endif
    }

    var body: some View {
        switch style {
        case .capsule:
            capsuleContent
        case .card:
            cardContent
        #if os(macOS)
        case .docked:
            dockedContent
        #endif
        }
    }

    private var capsuleContent: some View {
        HStack(spacing: 14) {
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.voxlineAccent)
                    .frame(width: 30, height: 30)
                    .background(Color.voxlineAccent.opacity(0.15), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? String(localized: "暂停", bundle: appLocalizationBundle) : String(localized: "播放", bundle: appLocalizationBundle))

            Button {
                playback.seekRelative(by: -5.0)
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "快退 5 秒", bundle: appLocalizationBundle))
            .help(String(localized: "快退 5 秒", bundle: appLocalizationBundle))

            Button {
                playback.seekRelative(by: 5.0)
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "快进 5 秒", bundle: appLocalizationBundle))
            .help(String(localized: "快进 5 秒", bundle: appLocalizationBundle))

            PlaybackCurrentTime(playback: playback)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)

            PlaybackProgressSlider(playback: playback)
                .controlSize(.mini)
                .tint(Color.voxlineAccent)
                .accessibilityLabel(String(localized: "播放进度", bundle: appLocalizationBundle))
                .frame(minWidth: 100)

            Text(playback.formattedDuration)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)

            speedMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .liquidGlassCapsule()
        .disabled(!playback.isReady)
    }

    private var cardContent: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                PlaybackCurrentTime(playback: playback)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                PlaybackProgressSlider(playback: playback, minimumDuration: 0.1)
                    .tint(Color.voxlineAccent)
                    .disabled(!playback.isReady)

                Text(playback.formattedDuration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)

            HStack(spacing: 30) {
                Button {
                    playback.seekRelative(by: -5)
                } label: {
                    Image(systemName: "gobackward.5")
                        .font(.title3)
                }
                .accessibilityLabel(String(localized: "快退 5 秒", bundle: appLocalizationBundle))

                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.voxlineAccent)
                }
                .accessibilityLabel(playback.isPlaying ? String(localized: "暂停", bundle: appLocalizationBundle) : String(localized: "播放", bundle: appLocalizationBundle))

                Button {
                    playback.seekRelative(by: 5)
                } label: {
                    Image(systemName: "goforward.5")
                        .font(.title3)
                }
                .accessibilityLabel(String(localized: "快进 5 秒", bundle: appLocalizationBundle))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    private var speedMenu: some View {
        Menu {
            Button("0.5x") { playback.setRate(0.5) }
            Button("0.75x") { playback.setRate(0.75) }
            Button(String(localized: "1.0x (正常)", bundle: appLocalizationBundle)) { playback.setRate(1.0) }
            Button("1.25x") { playback.setRate(1.25) }
            Button("1.5x") { playback.setRate(1.5) }
            Button("2.0x") { playback.setRate(2.0) }
        } label: {
            Text(String(format: "%.2fx", playback.playbackRate))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.secondary.opacity(0.10), in: .capsule)
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                )
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .menuIndicator(.hidden)
    }

    #if os(macOS)
    // MARK: - Docked Style
    private var dockedContent: some View {
        ViewThatFits(in: .horizontal) {
            // Wide player: Single-row layout
            HStack(spacing: 10) {
                dockedTransport
                dockedTime.fixedSize()
                dockedProgress.frame(minWidth: 70)
                speedMenu
                volumeControl
                fullscreenButton
            }

            // Narrow player: Two-row compact layout
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    PlaybackCurrentTime(playback: playback)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    dockedProgress
                    Text(playback.formattedDuration)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    dockedTransport
                    Spacer(minLength: 4)
                    speedMenu
                    volumeControl
                    fullscreenButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background {
            Color(nsColor: .windowBackgroundColor).opacity(0.8)
                .background(.regularMaterial)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.4))
                .frame(height: 1)
        }
        .disabled(!playback.isReady)
    }

    private var dockedTransport: some View {
        HStack(spacing: 10) {
            Button {
                playback.seekRelative(by: -5.0)
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "快退 5 秒", bundle: appLocalizationBundle))
            .help(String(localized: "快退 5 秒", bundle: appLocalizationBundle))

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        LinearGradient(
                            colors: [Color.voxlineAccent, Color.voxlineAccent.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: .circle
                    )
                    .shadow(color: Color.voxlineAccent.opacity(0.35), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? String(localized: "暂停", bundle: appLocalizationBundle) : String(localized: "播放", bundle: appLocalizationBundle))
            .help(playback.isPlaying ? String(localized: "暂停 (空格键)", bundle: appLocalizationBundle) : String(localized: "播放 (空格键)", bundle: appLocalizationBundle))

            Button {
                playback.seekRelative(by: 5.0)
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "快进 5 秒", bundle: appLocalizationBundle))
            .help(String(localized: "快进 5 秒", bundle: appLocalizationBundle))
        }
        .fixedSize()
    }

    private var dockedTime: some View {
        HStack(spacing: 3) {
            PlaybackCurrentTime(playback: playback)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text("/")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(playback.formattedDuration)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var dockedProgress: some View {
        PlaybackProgressSlider(playback: playback)
            .controlSize(.mini)
            .tint(Color.voxlineAccent)
            .accessibilityLabel(String(localized: "播放进度", bundle: appLocalizationBundle))
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Button {
                playback.toggleMute()
            } label: {
                Image(systemName: playback.isMuted || playback.volume == 0 ? "speaker.slash.fill" : (playback.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isMuted ? String(localized: "取消静音", bundle: appLocalizationBundle) : String(localized: "静音", bundle: appLocalizationBundle))
            .help(playback.isMuted ? String(localized: "取消静音", bundle: appLocalizationBundle) : String(localized: "静音", bundle: appLocalizationBundle))

            Slider(
                value: Binding(
                    get: { Double(playback.isMuted ? 0 : playback.volume) },
                    set: { playback.setVolume(Float($0)) }
                ),
                in: 0...1.0
            )
            .controlSize(.mini)
            .frame(width: 48)
            .accessibilityLabel(String(localized: "音量", bundle: appLocalizationBundle))
        }
    }

    private var fullscreenButton: some View {
        Button {
            (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
        } label: {
            Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFullScreen ? String(localized: "退出全屏", bundle: appLocalizationBundle) : String(localized: "全屏", bundle: appLocalizationBundle))
        .help(isFullScreen ? String(localized: "退出全屏", bundle: appLocalizationBundle) : String(localized: "全屏 (⌃⌘F)", bundle: appLocalizationBundle))
    }

    private var isFullScreen: Bool {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.styleMask.contains(.fullScreen) == true
    }
    #endif
}

/// Read the playback clock here so its 30 Hz updates do not invalidate the control bar.
private struct PlaybackCurrentTime: View {
    let playback: MediaPlaybackController

    var body: some View {
        Text(playback.formattedCurrentTime)
    }
}

/// Slider evaluates its binding in this leaf, independently of transport buttons and material.
private struct PlaybackProgressSlider: View {
    let playback: MediaPlaybackController
    var minimumDuration: Double = 1
    @State private var isScrubbing = false
    @State private var scrubPosition: Double?

    var body: some View {
        Slider(
            value: Binding(
                get: { scrubPosition ?? playback.currentTimeSeconds },
                set: { value in
                    if isScrubbing { scrubPosition = value }
                    playback.seek(to: value, isScrubbing: isScrubbing)
                }
            ),
            in: 0...max(playback.durationSeconds, minimumDuration),
            onEditingChanged: { editing in
                isScrubbing = editing
                if editing { scrubPosition = playback.currentTimeSeconds }
                else if let position = scrubPosition {
                    scrubPosition = nil
                    playback.seek(to: position)
                }
            }
        )
    }
}
