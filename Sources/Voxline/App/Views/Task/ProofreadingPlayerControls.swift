import SwiftUI
import VoxlineMedia

struct ProofreadingPlayerControls: View {
    @Bindable var playback: MediaPlaybackController
    var style: Style = .capsule

    enum Style {
        case capsule
        case card
    }

    var body: some View {
        switch style {
        case .capsule:
            capsuleContent
        case .card:
            cardContent
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

            Text(playback.formattedCurrentTime)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)

            Slider(
                value: Binding(
                    get: { playback.currentTimeSeconds },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.durationSeconds, 1.0)
            )
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
                Text(playback.formattedCurrentTime)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { playback.currentTimeSeconds },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.durationSeconds, 0.1)
                )
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
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: .capsule)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
    }
}
