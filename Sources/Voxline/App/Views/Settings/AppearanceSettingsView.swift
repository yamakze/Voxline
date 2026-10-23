#if os(macOS)
import SwiftUI

public struct AppearanceSettingsView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var manager = AppearanceManager.shared
    @State private var draftTintOpacity: Double
    @State private var isEditingTintOpacity = false

    public init() {
        _draftTintOpacity = State(initialValue: AppearanceManager.shared.tintOpacity)
    }

    private var previewColorScheme: ColorScheme {
        switch manager.mode {
        case .system:
            return systemColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. 顶部预览示意图
                Text(String(localized: "预览", bundle: appLocalizationBundle))
                    .font(.headline)

                previewMockWindow
                    .frame(height: 170)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
                    .shadow(color: .black.opacity(previewColorScheme == .dark ? 0.35 : 0.08), radius: 10, y: 4)

                // 2. 外观模式选择器
                Text(String(localized: "外观模式", bundle: appLocalizationBundle))
                    .font(.headline)

                Picker(String(localized: "外观模式", bundle: appLocalizationBundle), selection: $manager.mode) {
                    Text(String(localized: "跟随系统", bundle: appLocalizationBundle)).tag(AppearanceMode.system)
                    Text(String(localized: "浅色", bundle: appLocalizationBundle)).tag(AppearanceMode.light)
                    Text(String(localized: "深色", bundle: appLocalizationBundle)).tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // 3. 细节区
                Text(String(localized: "细节", bundle: appLocalizationBundle))
                    .font(.headline)

                VStack(spacing: 16) {
                    HStack {
                        Text(String(localized: "微染主题色", bundle: appLocalizationBundle))
                        Spacer()
                        HStack(spacing: 16) {
                            tintSwatch(
                                option: .appIcon,
                                label: String(localized: "默认", bundle: appLocalizationBundle)
                            )
                            tintSwatch(
                                option: .none,
                                label: String(localized: "无", bundle: appLocalizationBundle)
                            )
                        }
                    }

                    Divider()

                    HStack {
                        Text(String(localized: "主题色浓度", bundle: appLocalizationBundle))
                            .foregroundStyle(manager.tintOption == .none ? .secondary : .primary)
                        Slider(value: Binding(get: { draftTintOpacity }, set: { value in
                            draftTintOpacity = value
                            // Keyboard and accessibility changes do not always start a drag session.
                            if !isEditingTintOpacity { manager.tintOpacity = value }
                        }), in: 0...0.08, step: 0.005, onEditingChanged: { editing in
                            isEditingTintOpacity = editing
                            if !editing { manager.tintOpacity = draftTintOpacity }
                        })
                            .accessibilityLabel(String(localized: "主题色浓度", bundle: appLocalizationBundle))
                            .disabled(manager.tintOption == .none)
                        Text((manager.tintOption == .none ? 0 : draftTintOpacity).formatted(.percent.precision(.fractionLength(0...1))))
                            .monospacedDigit()
                            .foregroundStyle(manager.tintOption == .none ? .tertiary : .primary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .animation(.easeInOut(duration: 0.2), value: manager.tintOption)
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            }
            .padding(24)
        }
        .onDisappear {
            if isEditingTintOpacity { manager.tintOpacity = draftTintOpacity }
            isEditingTintOpacity = false
        }
        .onAppear { draftTintOpacity = manager.tintOpacity }
    }

    // MARK: - 真实联动预览微视窗
    private var previewMockWindow: some View {
        let isDark = previewColorScheme == .dark
        let windowBg = isDark ? Color(red: 0.12, green: 0.13, blue: 0.15) : Color(red: 0.96, green: 0.96, blue: 0.97)
        let sidebarBg = isDark ? Color(red: 0.16, green: 0.17, blue: 0.19) : Color(red: 0.92, green: 0.92, blue: 0.93)

        return VStack(spacing: 0) {
            // 迷你标题栏（交通灯小圆点）
            HStack(spacing: 6) {
                Circle().fill(Color(red: 1.0, green: 0.38, blue: 0.35)).frame(width: 8, height: 8)
                Circle().fill(Color(red: 1.0, green: 0.76, blue: 0.20)).frame(width: 8, height: 8)
                Circle().fill(Color(red: 0.20, green: 0.78, blue: 0.35)).frame(width: 8, height: 8)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 7)
            .background(sidebarBg)

            Divider()

            HStack(spacing: 0) {
                // 迷你侧边栏
                VStack(alignment: .leading, spacing: 6) {
                    // 激活项：“全部任务”
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 10))
                        Text(String(localized: "全部任务", bundle: appLocalizationBundle))
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.voxlineAccent.opacity(isDark ? 0.25 : 0.15))
                    }
                    .foregroundStyle(Color.voxlineAccent)

                    HStack(spacing: 6) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 10))
                        Text(String(localized: "翻译服务", bundle: appLocalizationBundle))
                            .font(.system(size: 11))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10))
                        Text(String(localized: "云端转写", bundle: appLocalizationBundle))
                            .font(.system(size: 11))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(8)
                .frame(width: 140, alignment: .leading)
                .background(sidebarBg)

                Divider()

                // 迷你工作区（带真实微染叠加）
                ZStack {
                    windowBg

                    // 微染光晕注入（开启减少透明度时统一不透明系统背景）
                    if !reduceTransparency, let tint = manager.resolvedTintColor(opacity: draftTintOpacity, strength: 0.40) {
                        tint
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        // 顶部迷你控制条
                        HStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.20))
                                .frame(width: 80, height: 10)
                            Spacer()
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(width: 32, height: 10)
                        }

                        // 迷你任务卡片（真实反映 NativeControlSurface）
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(manager.tintOption == .appIcon
                                          ? Color.voxlineGlacierAzure.opacity(0.20)
                                          : Color.secondary.opacity(0.15))
                                    .frame(width: 28, height: 28)
                                Image(systemName: "waveform")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(manager.tintOption == .appIcon ? Color.voxlineGlacierAzure : .primary)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isDark ? Color.white.opacity(0.70) : Color.black.opacity(0.70))
                                    .frame(width: 120, height: 8)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.35))
                                    .frame(width: 70, height: 6)
                            }

                            Spacer()

                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                        .padding(10)
                        .nativeControlSurface(cornerRadius: 8)

                        // 迷你字幕行模拟
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.25))
                                .frame(width: 160, height: 6)
                            Spacer()
                        }
                        .padding(.horizontal, 4)

                        Spacer()
                    }
                    .padding(12)
                }
            }
        }
        .environment(\.colorScheme, previewColorScheme)
        .environment(\.voxlinePreviewTintOpacity, draftTintOpacity)
    }

    // MARK: - 二元微彩色块
    private func tintSwatch(option: TintOption, label: String) -> some View {
        let isSelected = manager.tintOption == option

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                manager.tintOption = option
            }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    if option == .appIcon {
                        // 冰川天青渐变
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.22, green: 0.74, blue: 0.97),
                                        Color(red: 0.055, green: 0.647, blue: 0.914)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 18, height: 18)
                    } else {
                        // 中性灰底色 + 极简纯净环
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.40), lineWidth: 1.5)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                            .frame(width: 18, height: 18)
                            .overlay {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.55))
                                    .frame(width: 1.5, height: 10)
                                    .rotationEffect(.degrees(45))
                            }
                    }
                }
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(option == .appIcon ? Color.voxlineGlacierAzure : Color.primary.opacity(0.50), lineWidth: 2)
                            .frame(width: 24, height: 24)
                    }
                }
                .frame(width: 26, height: 26)

                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
