import SwiftUI
#if os(iOS)
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
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
        } else {
            content
                .background {
                    shape.fill(
                        colorScheme == .dark
                            ? Color(nsColor: .controlBackgroundColor).opacity(0.70)
                            : Color(nsColor: .controlBackgroundColor)
                    )
                    .background(.regularMaterial, in: shape)
                }
                .overlay {
                    shape.strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.10)
                            : Color.black.opacity(0.06),
                        lineWidth: 1
                    )
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.035),
                    radius: colorScheme == .dark ? 6 : 4,
                    x: 0,
                    y: colorScheme == .dark ? 3 : 1.5
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
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        } else {
            content
                .background(.ultraThinMaterial, in: .capsule)
                .overlay(
                    Capsule().strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.20) : Color.white.opacity(0.55),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.10), radius: 10, y: 4)
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
