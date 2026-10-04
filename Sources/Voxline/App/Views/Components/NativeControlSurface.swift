import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct NativeControlSurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(cornerRadius: CGFloat = 14) {
        self.cornerRadius = cornerRadius
    }

    @ViewBuilder public func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color.voxlineControlBackground, in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 26, iOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

public struct NativeGlassCapsuleSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    @ViewBuilder public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color.voxlineControlBackground, in: .capsule)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        } else if #available(macOS 26, iOS 26, *) {
            content
                .glassEffect(.regular, in: .capsule)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        } else {
            content
                .background(.ultraThinMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        }
    }
}

public struct NativeSubtitleOverlaySurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    @ViewBuilder public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color.black, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                )
        } else if #available(macOS 26, iOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .background(Color.black.opacity(0.45), in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
                .background(Color.black.opacity(0.55), in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
        }
    }
}

public extension View {
    func liquidGlassSurface(cornerRadius: CGFloat = 14) -> some View {
        modifier(NativeControlSurface(cornerRadius: cornerRadius))
    }

    func liquidGlassCapsule() -> some View {
        modifier(NativeGlassCapsuleSurface())
    }

    func subtitleOverlaySurface() -> some View {
        modifier(NativeSubtitleOverlaySurface())
    }
}

extension Color {
    static var voxlineControlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}
