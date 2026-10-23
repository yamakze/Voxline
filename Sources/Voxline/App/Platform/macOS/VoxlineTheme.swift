#if os(macOS)
import SwiftUI
import AppKit

public extension Color {
    /// Voxline 品牌强调色：跟随系统原生强调色 (System Accent)
    /// 自动适配用户的 macOS 外观偏好设置（多色/蓝/紫/粉/红/橙/黄/绿/石墨）与深浅色模式。
    static let voxlineAccent = Color.accentColor

    /// 辅助色：中性次级内容色
    static let voxlineGraphite = Color.secondary

    /// 正在播放/活动字幕条目的高质感底色（跟随系统强调色微透明度）
    static let voxlineActiveCueBackground = Color.accentColor.opacity(0.12)

    /// 正在播放/活动字幕条目的精致微描边
    static let voxlineActiveCueBorder = Color.accentColor.opacity(0.25)

    /// 双语译文使用适配深浅背景的琥珀色。
    static let voxlineTranslationText = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.98, green: 0.74, blue: 0.32, alpha: 1.0)
            : NSColor(red: 0.64, green: 0.34, blue: 0.04, alpha: 1.0)
    }))

    /// Voxline AppIcon 提取的冰川天青水蓝色微染基准色
    static let voxlineGlacierAzure = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1.0) // Sky 400
            : NSColor(red: 0.055, green: 0.647, blue: 0.914, alpha: 1.0) // Sky 500
    }))
}

/// 外观模式枚举
public enum AppearanceMode: Int, CaseIterable, Identifiable {
    case system = 0
    case light = 1
    case dark = 2

    public var id: Int { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 主题微染选项（二元：默认 AppIcon 冰川天青蓝 vs 无）
public enum TintOption: String, CaseIterable, Identifiable {
    case appIcon = "appIcon"
    case none = "none"

    public var id: String { rawValue }
}

/// 全局外观与微染状态管理器
@Observable @MainActor
public final class AppearanceManager {
    public static let shared = AppearanceManager()

    private let modeKey = "voxline.appearance.mode"
    private let tintOptionKey = "voxline.appearance.tintOption"
    private let tintOpacityKey = "voxline.appearance.tintOpacity"

    public var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        }
    }

    public var tintOption: TintOption {
        didSet {
            UserDefaults.standard.set(tintOption.rawValue, forKey: tintOptionKey)
        }
    }

    /// 范围 0.0 ~ 0.08，默认 0.05
    public var tintOpacity: Double {
        didSet {
            UserDefaults.standard.set(tintOpacity, forKey: tintOpacityKey)
        }
    }

    private init() {
        let savedMode = UserDefaults.standard.integer(forKey: modeKey)
        self.mode = AppearanceMode(rawValue: savedMode) ?? .system

        let savedTint = UserDefaults.standard.string(forKey: tintOptionKey)
        self.tintOption = (savedTint == TintOption.none.rawValue) ? .none : .appIcon

        let savedOpacity = UserDefaults.standard.object(forKey: tintOpacityKey) as? Double
        self.tintOpacity = savedOpacity ?? 0.05
    }

    public func resolvedTintColor(opacity: Double? = nil, strength: Double = 1) -> Color? {
        guard tintOption == .appIcon else { return nil }
        let concentration = opacity ?? tintOpacity
        guard concentration > 0 else { return nil }
        return Color.voxlineGlacierAzure.opacity(concentration * strength)
    }
}

extension EnvironmentValues {
    @Entry var voxlinePreviewTintOpacity: Double? = nil
}

/// 窗口或顶级视图微染背景修饰器
public struct VoxlineMicroTintBackgroundModifier: ViewModifier {
    private var manager = AppearanceManager.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    public func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                        .ignoresSafeArea()
                } else if let tint = manager.resolvedTintColor(strength: 0.40) {
                    tint
                        .ignoresSafeArea()
                }
            }
    }
}

public extension View {
    func voxlineMicroTintBackground() -> some View {
        modifier(VoxlineMicroTintBackgroundModifier())
    }

}

/// 全局 Dock 图标注入管理器
@MainActor
public final class VoxlineIconManager {
    public static let shared = VoxlineIconManager()

    private let appIcon: NSImage?

    private init() {
        appIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
    }

    /// 强制为当前运行中的进程刷新 Dock 图标
    public func ensureDockIconIsSet() {
        if let iconImage = loadAppIcon() {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    public func loadAppIcon() -> NSImage? {
        appIcon
    }
}

/// Voxline 应用图标视图组件
public struct VoxlineAppIconView: View {
    public let size: CGFloat

    public init(size: CGFloat = 64) {
        self.size = size
    }

    public var body: some View {
        if let iconImage = VoxlineIconManager.shared.loadAppIcon() {
            Image(nsImage: iconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            // 极简原生 Squircle 徽标备选
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                Image(systemName: "waveform")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .frame(width: size, height: size)
        }
    }
}

#endif
