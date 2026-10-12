import SwiftUI
import VoxlineCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private struct AppIconView: View {
    var size: CGFloat = 40

    var body: some View {
        #if os(macOS)
        if let icon = NSApp?.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            fallbackIcon
        }
        #elseif os(iOS)
        if let uiImage = loadIOSAppIcon() {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            fallbackIcon
        }
        #else
        fallbackIcon
        #endif
    }

    #if os(iOS)
    private func loadIOSAppIcon() -> UIImage? {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
           let lastIcon = iconFiles.last,
           let image = UIImage(named: lastIcon) {
            return image
        }
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons~ipad"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
           let lastIcon = iconFiles.last,
           let image = UIImage(named: lastIcon) {
            return image
        }
        for name in ["AppIcon60x60", "AppIcon76x76", "AppIcon"] {
            if let image = UIImage(named: name) {
                return image
            }
        }
        if let path = Bundle.main.path(forResource: "AppIcon60x60@2x", ofType: "png") ??
                      Bundle.main.path(forResource: "AppIcon76x76@2x~ipad", ofType: "png"),
           let image = UIImage(contentsOfFile: path) {
            return image
        }
        return nil
    }
    #endif

    private var fallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color.voxlineAccent.gradient)
            Image(systemName: "arrow.clockwise")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

#if os(macOS)
public struct MacCheckForUpdatesButton: View {
    @ObservedObject private var updater = MacUpdater.shared

    public init() {}

    public var body: some View {
        Button(String(localized: "检查更新…", bundle: appLocalizationBundle)) {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        .accessibilityLabel(String(localized: "检查更新", bundle: appLocalizationBundle))
    }
}
#endif

public struct AppUpdatesSettingsView: View {
    public init() {}

    public var body: some View {
        #if os(macOS)
        MacAppUpdatesSettingsView()
        #elseif os(iOS)
        IOSAppUpdatesSettingsView()
        #else
        EmptyView()
        #endif
    }
}

#if os(macOS)
private struct MacAppUpdatesSettingsView: View {
    @ObservedObject private var updater = MacUpdater.shared

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var currentBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private var versionText: String {
        if let build = currentBuild {
            String(format: String(localized: "版本 %@ (%@)", bundle: appLocalizationBundle), currentVersion, build)
        } else {
            String(format: String(localized: "版本 %@", bundle: appLocalizationBundle), currentVersion)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                versionCard

                optionsCard

                if let error = updater.errorMessage {
                    errorBanner(error)
                }
            }
            .frame(maxWidth: 540)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var versionCard: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIconView(size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("Voxline")
                    .font(.headline)

                Text(versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                updater.checkForUpdates()
            } label: {
                Label(String(localized: "检查更新…", bundle: appLocalizationBundle), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!updater.canCheckForUpdates)
            .accessibilityLabel(String(localized: "检查更新", bundle: appLocalizationBundle))
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 14)
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "更新选项", bundle: appLocalizationBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(String(localized: "自动检查更新", bundle: appLocalizationBundle), isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticChecking($0) }
            ))
            .disabled(!updater.isConfigured)
            .accessibilityLabel(String(localized: "自动检查更新", bundle: appLocalizationBundle))

            Divider()

            Toggle(String(localized: "自动下载更新", bundle: appLocalizationBundle), isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.setAutomaticDownloads($0) }
            ))
            .disabled(!updater.isConfigured || !updater.automaticallyChecksForUpdates)
            .accessibilityLabel(String(localized: "自动下载更新", bundle: appLocalizationBundle))

            if !updater.isConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(String(localized: "此版本未配置自动更新通道", bundle: appLocalizationBundle))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 14)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "更新检查失败", bundle: appLocalizationBundle))
                    .font(.subheadline.weight(.medium))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
#endif

#if os(iOS)
private struct IOSAppUpdatesSettingsView: View {
    @State private var session = ReleaseUpdateSession()
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                versionHeaderCard

                statusCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .task {
            await session.check()
        }
        .navigationTitle(String(localized: "检查更新", bundle: appLocalizationBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionHeaderCard: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconView(size: 40)

            Text("Voxline")
                .font(.headline)

            Spacer()

            Text(String(format: String(localized: "版本 %@", bundle: appLocalizationBundle), session.currentVersion ?? "—"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 14)
    }

    @ViewBuilder
    private var statusCard: some View {
        switch session.state {
        case .idle:
            EmptyView()

        case .checking:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "正在检查更新…", bundle: appLocalizationBundle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .liquidGlassSurface(cornerRadius: 14)

        case .upToDate:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                    .accessibilityHidden(true)
                Text(String(localized: "当前已是最新版本", bundle: appLocalizationBundle))
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(16)
            .liquidGlassSurface(cornerRadius: 14)

        case .noRelease:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                        .accessibilityHidden(true)
                    Text(String(localized: "暂无可用更新", bundle: appLocalizationBundle))
                        .font(.subheadline.weight(.medium))
                }
                HStack {
                    Spacer()
                    Button {
                        openURL(session.releasesURL)
                    } label: {
                        Label(String(localized: "前往 GitHub", bundle: appLocalizationBundle), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(16)
            .liquidGlassSurface(cornerRadius: 14)

        case .failed(let error):
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "更新检查失败", bundle: appLocalizationBundle))
                            .font(.subheadline.weight(.medium))
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                HStack {
                    Spacer()
                    Button {
                        Task { await session.check() }
                    } label: {
                        Label(String(localized: "重试", bundle: appLocalizationBundle), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 12))

        case .available(let release):
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.voxlineAccent)
                        .font(.title3)
                        .accessibilityHidden(true)
                    Text(String(format: String(localized: "发现新版本：%@", bundle: appLocalizationBundle), release.version))
                        .font(.headline)
                    Spacer()
                }

                if let body = release.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "更新内容", bundle: appLocalizationBundle))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView {
                            Text(.init(body))
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
                    }
                }

                HStack(spacing: 12) {
                    if let ipaURL = release.ipaURL {
                        Button {
                            openURL(ipaURL)
                        } label: {
                            Label(String(localized: "下载 IPA", bundle: appLocalizationBundle), systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Button {
                        openURL(release.htmlURL)
                    } label: {
                        Label(String(localized: "版本详情", bundle: appLocalizationBundle), systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(16)
            .liquidGlassSurface(cornerRadius: 14)
        }
    }
}
#endif
