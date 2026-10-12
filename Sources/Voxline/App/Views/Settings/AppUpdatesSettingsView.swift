import SwiftUI
import VoxlineCore
#if os(macOS)
import AppKit

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                versionCard

                optionsCard

                if let error = updater.errorMessage {
                    errorBanner(error)
                }
            }
            .padding(24)
        }
    }

    private var versionCard: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.voxlineAccent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Voxline")
                    .font(.headline)

                if let build = currentBuild {
                    Text(String(format: String(localized: "当前版本：%@ (%@)", bundle: appLocalizationBundle), currentVersion, build))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: String(localized: "当前版本：%@", bundle: appLocalizationBundle), currentVersion))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                updater.checkForUpdates()
            } label: {
                Label(String(localized: "检查更新…", bundle: appLocalizationBundle), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
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

            Toggle(String(localized: "自动下载并安装更新", bundle: appLocalizationBundle), isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.setAutomaticDownloads($0) }
            ))
            .disabled(!updater.isConfigured || !updater.automaticallyChecksForUpdates)
            .accessibilityLabel(String(localized: "自动下载并安装更新", bundle: appLocalizationBundle))
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 14)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.headline)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "更新异常", bundle: appLocalizationBundle))
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))
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
            VStack(alignment: .leading, spacing: 18) {
                versionHeaderCard

                statusCard
            }
            .padding(20)
        }
        .navigationTitle(String(localized: "检查更新", bundle: appLocalizationBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionHeaderCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.voxlineAccent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Voxline")
                    .font(.headline)

                Text(String(format: String(localized: "当前版本：%@", bundle: appLocalizationBundle), session.currentVersion ?? "—"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await session.check() }
            } label: {
                if session.state == .checking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(String(localized: "检查更新", bundle: appLocalizationBundle))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(session.state == .checking)
            .accessibilityLabel(String(localized: "检查更新", bundle: appLocalizationBundle))
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 14)
    }

    @ViewBuilder
    private var statusCard: some View {
        switch session.state {
        case .idle:
            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(String(localized: "尚未检查更新", bundle: appLocalizationBundle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .liquidGlassSurface(cornerRadius: 14)

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
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "当前已是最新版本", bundle: appLocalizationBundle))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(String(format: String(localized: "当前版本：%@", bundle: appLocalizationBundle), session.currentVersion ?? "—"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
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
                    Text(String(localized: "未找到正式发布版本。", bundle: appLocalizationBundle))
                        .font(.headline)
                }
                HStack {
                    Spacer()
                    Button {
                        openURL(session.releasesURL)
                    } label: {
                        Label(String(localized: "在 GitHub 中查看", bundle: appLocalizationBundle), systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "在浏览器中查看 GitHub 发行页", bundle: appLocalizationBundle))
                }
            }
            .padding(16)
            .liquidGlassSurface(cornerRadius: 14)

        case .failed(let error):
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "更新检查失败", bundle: appLocalizationBundle))
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
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
                    .accessibilityLabel(String(localized: "重试检查更新", bundle: appLocalizationBundle))
                }
            }
            .padding(14)
            .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))

        case .available(let release):
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.voxlineAccent)
                        .font(.title3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: String(localized: "发现新版本：%@", bundle: appLocalizationBundle), release.version))
                            .font(.headline)
                        if let current = session.currentVersion {
                            Text(String(format: String(localized: "当前安装版本：%@", bundle: appLocalizationBundle), current))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                        .controlSize(.regular)
                        .accessibilityLabel(String(localized: "下载 IPA 文件", bundle: appLocalizationBundle))
                    }

                    Button {
                        openURL(release.htmlURL)
                    } label: {
                        Label(String(localized: "版本详情", bundle: appLocalizationBundle), systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityLabel(String(localized: "查看版本详情", bundle: appLocalizationBundle))
                }
                .padding(.top, 4)
            }
            .padding(16)
            .liquidGlassSurface(cornerRadius: 14)
        }
    }
}
#endif
