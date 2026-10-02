import SwiftUI
import AppKit

public extension Color {
    /// Voxline 品牌主映像色：原生极简黑 (Monochrome / Apple Pro Black)
    /// 浅色模式下为纯黑/碳黑，深色模式下为纯白/亮白，呈现极简、克制、专业的 Pro 风格。
    static let voxlineAccent = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 0.96, alpha: 1.0)
        } else {
            return NSColor(white: 0.10, alpha: 1.0)
        }
    }))

    /// 辅助色：中性石墨灰
    static let voxlineGraphite = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 0.65, alpha: 1.0)
        } else {
            return NSColor(white: 0.35, alpha: 1.0)
        }
    }))

    /// 正在播放/活动字幕条目的高质感中性底色
    static let voxlineActiveCueBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 1.0, alpha: 0.12)
        } else {
            return NSColor(white: 0.0, alpha: 0.06)
        }
    }))

    /// 正在播放/活动字幕条目的精致微描边
    static let voxlineActiveCueBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 1.0, alpha: 0.22)
        } else {
            return NSColor(white: 0.0, alpha: 0.15)
        }
    }))
}

/// 全局 Dock 图标注入管理器
@MainActor
public final class VoxlineIconManager {
    public static let shared = VoxlineIconManager()

    private init() {}

    /// 强制为当前运行中的进程刷新 Dock 图标
    public func ensureDockIconIsSet() {
        if let iconImage = loadAppIcon() {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    public func loadAppIcon() -> NSImage? {
        // 1. 尝试从 App Bundle Resources 读取
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }

        // 2. 尝试从 Contents/Resources/AppIcon.icns 路径直接读取
        let bundleResourceURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns")
        if FileManager.default.fileExists(atPath: bundleResourceURL.path),
           let img = NSImage(contentsOf: bundleResourceURL) {
            return img
        }

        // 3. 尝试从可执行文件所在相对目录向上寻找 Resources/AppIcon.icns 或 AppIcon.png
        var searchDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidateICNS = searchDir.appendingPathComponent("Resources/AppIcon.icns")
            if FileManager.default.fileExists(atPath: candidateICNS.path),
               let img = NSImage(contentsOf: candidateICNS) {
                return img
            }
            let candidatePNG = searchDir.appendingPathComponent("Resources/AppIcon.png")
            if FileManager.default.fileExists(atPath: candidatePNG.path),
               let img = NSImage(contentsOf: candidatePNG) {
                return img
            }
            searchDir.deleteLastPathComponent()
        }

        // 4. 读取系统当前已有图标
        return NSApp?.applicationIconImage
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
