#if os(iOS)
import SwiftUI
import UIKit

public extension Color {
    /// Voxline 品牌主映像色：原生极简黑 (Monochrome / Apple Pro Black)
    /// 浅色模式下为纯黑/碳黑，深色模式下为纯白/亮白
    static let voxlineAccent = Color(uiColor: UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(white: 0.96, alpha: 1.0)
            : UIColor(white: 0.10, alpha: 1.0)
    })

    /// 辅助色：中性石墨灰
    static let voxlineGraphite = Color(uiColor: UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(white: 0.65, alpha: 1.0)
            : UIColor(white: 0.35, alpha: 1.0)
    })

    /// 正在播放/活动字幕条目的高质感中性底色
    static let voxlineActiveCueBackground = Color(uiColor: UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.12)
            : UIColor(white: 0.0, alpha: 0.06)
    })

    /// 正在播放/活动字幕条目的精致微描边
    static let voxlineActiveCueBorder = Color(uiColor: UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.22)
            : UIColor(white: 0.0, alpha: 0.15)
    })
}
#endif
