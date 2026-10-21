#if os(iOS)
import SwiftUI
import UIKit

public extension Color {
    /// Voxline 品牌强调色：跟随系统原生强调色 (System Accent)
    /// 自动适配 iOS 系统强调色与深浅色模式。
    static let voxlineAccent = Color.accentColor

    /// 辅助色：中性次级内容色
    static let voxlineGraphite = Color.secondary

    /// 正在播放/活动字幕条目的高质感底色（跟随系统强调色微透明度）
    static let voxlineActiveCueBackground = Color.accentColor.opacity(0.12)

    /// 正在播放/活动字幕条目的精致微描边
    static let voxlineActiveCueBorder = Color.accentColor.opacity(0.25)

    /// 双语译文使用适配深浅背景的琥珀色。
    static let voxlineTranslationText = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.98, green: 0.74, blue: 0.32, alpha: 1.0)
            : UIColor(red: 0.64, green: 0.34, blue: 0.04, alpha: 1.0)
    })
}
#endif
