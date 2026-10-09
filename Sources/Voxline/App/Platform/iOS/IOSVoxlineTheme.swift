#if os(iOS)
import SwiftUI
import UIKit

public extension Color {
    /// Voxline 品牌主映像色：专业音频琥珀橙 (Studio Amber)
    /// 浅色模式下为沉稳饱满的暖琥珀橙 (#EB6614)，深色模式下为透亮温暖的发光琥珀橙 (#FFA028)。
    static let voxlineAccent = Color(uiColor: UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.627, blue: 0.157, alpha: 1.0)
            : UIColor(red: 0.922, green: 0.400, blue: 0.078, alpha: 1.0)
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
            ? UIColor(red: 1.0, green: 0.627, blue: 0.157, alpha: 0.12)
            : UIColor(red: 0.922, green: 0.400, blue: 0.078, alpha: 0.08)
    })

    /// 正在播放/活动字幕条目的精致微描边
    static let voxlineActiveCueBorder = Color(uiColor: UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.627, blue: 0.157, alpha: 0.28)
            : UIColor(red: 0.922, green: 0.400, blue: 0.078, alpha: 0.20)
    })
}
#endif
