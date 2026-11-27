import SwiftUI

// MARK: - Frosted glass

/// The browser's glass: a blur material with its own tint and a soft edge
/// that is lit from above. Built on plain materials on purpose, not on
/// Apple's Liquid Glass, so it looks the same on every iOS version.
private struct FrostedGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(dark ? Color.black.opacity(0.22) : Color.white.opacity(0.38))
                }
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(dark ? 0.24 : 0.75),
                            Color.white.opacity(dark ? 0.06 : 0.25),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            )
    }
}

extension View {
    /// Frosted capsule. `interactive` is kept for the callers that used the
    /// native glass's touch flex; the frosted glass has none.
    func liquidGlassCapsule(interactive: Bool = false) -> some View {
        modifier(FrostedGlass(shape: Capsule(style: .continuous)))
    }

    /// Soft lift. No fill: the page stays what the glass samples.
    func floatingGlassShadow(scheme: ColorScheme) -> some View {
        shadow(
            color: Color.black.opacity(scheme == .dark ? 0.35 : 0.16),
            radius: 14,
            x: 0,
            y: 6
        )
    }

    /// Floating frosted capsule: a pill that hovers over the page.
    func floatingGlassCapsule() -> some View {
        modifier(FrostedGlass(shape: Capsule(style: .continuous)))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }

    /// Floating frosted panel, for the open menu.
    func floatingGlassPanel(cornerRadius: CGFloat) -> some View {
        modifier(FrostedGlass(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }

    /// Frosted card over the page.
    func liquidGlassCard(cornerRadius: CGFloat) -> some View {
        modifier(FrostedGlass(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }
}

/// Soft bottom fade over the page. A live blur that ramps in towards the screen
/// bottom and stops at half strength, so the page dissolves into the controls
/// instead of being cut off by them.
struct PageBottomFade: View {
    /// Height of the ramp. The fade starts this far above the physical bottom.
    var height: CGFloat = 92

    /// Each layer blurs what the one below already blurred. The ramp stays
    /// linear because every layer is kept weak instead of saturating early.
    ///
    /// Few, weak layers on purpose: a material cannot blur without also laying
    /// a little of its own tone over the page. Every extra layer adds that tone
    /// faster than it adds blur, which is what turned the fade grey.
    private let layers = 2

    /// Strength of a single layer at the very bottom. Two layers end up at
    /// roughly 0.64 combined.
    private let strength = 0.4

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(0..<layers, id: \.self) { _ in
                layer
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var layer: some View {
        Rectangle()
            // Ultra-thin keeps the veil near invisible: thicker materials read
            // as a grey (over dark pages: brownish) panel rather than a blur.
            .fill(.ultraThinMaterial)
            .mask(
                LinearGradient(
                    colors: [.clear, .white.opacity(strength)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: height)
    }
}
