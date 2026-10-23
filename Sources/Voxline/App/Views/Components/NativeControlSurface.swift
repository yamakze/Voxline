import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public struct NativeControlSurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if os(macOS)
    @Environment(\.colorScheme) private var colorScheme
    #endif

    public init(cornerRadius: CGFloat = 14) {
        self.cornerRadius = cornerRadius
    }

    @ViewBuilder public func body(content: Content) -> some View {
        #if os(macOS)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color.voxlineControlBackground, in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
        } else {
            // These panels contain task and settings content; glass belongs to the control layer.
            let manager = AppearanceManager.shared
            content
                .background {
                    ZStack {
                        shape.fill(.regularMaterial)
                        if manager.tintOption == .appIcon && manager.tintOpacity > 0 {
                            shape.fill(manager.currentTintColor.opacity(manager.effectiveTintOpacity * 0.85))
                        }
                    }
                }
                .overlay(
                    shape.strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06),
                        lineWidth: 1
                    )
                )
        }
        #else
        if reduceTransparency {
            content.background(Color.voxlineControlBackground, in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 26, iOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
        #endif
    }
}

public struct NativeGlassCapsuleSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if os(macOS)
    @Environment(\.colorScheme) private var colorScheme
    #endif

    public init() {}

    @ViewBuilder public func body(content: Content) -> some View {
        #if os(macOS)
        if reduceTransparency {
            content
                .background(Color.voxlineControlBackground, in: .capsule)
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
        } else if #available(macOS 26, *) {
            let manager = AppearanceManager.shared
            content
                .glassEffect(.regular.tint(manager.currentTintColor.opacity(manager.effectiveTintOpacity * 0.90)), in: .capsule)
        } else {
            let manager = AppearanceManager.shared
            content
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        if manager.tintOption == .appIcon && manager.tintOpacity > 0 {
                            Capsule().fill(manager.currentTintColor.opacity(manager.effectiveTintOpacity * 0.90))
                        }
                    }
                }
                .overlay(
                    Capsule().strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.08),
                        lineWidth: 1
                    )
                )
        }
        #else
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
        #endif
    }
}

public struct NativeSubtitleOverlaySurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    @ViewBuilder public func body(content: Content) -> some View {
        #if os(macOS)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if reduceTransparency {
            content
                .background(Color.black, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.black.opacity(0.55))
                    }
                }
                .overlay(
                    shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
        }
        #else
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
        #endif
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

    static var voxlineWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var voxlineTextBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
