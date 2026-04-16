import SwiftUI

// Redesign spec §4: every brutalist primitive renders with a solid-color navy
// offset shadow positioned behind-and-below-left of the element. No blur, no
// gradient, no corner rounding. Small primitives use a 4px offset; medium and
// large primitives use 6px. The shadow is removed when the element is in its
// active/inverted state (spec §4 "Active / inverted state").

enum BrutalistShadowOffset: CGFloat {
    case small = 4
    case large = 6
}

struct BrutalistShadow: ViewModifier {
    let offset: CGFloat
    let color: Color

    init(offset: BrutalistShadowOffset = .small, color: Color = .ampNavy) {
        self.offset = offset.rawValue
        self.color = color
    }

    init(offsetValue: CGFloat, color: Color = .ampNavy) {
        self.offset = offsetValue
        self.color = color
    }

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Rectangle()
                    .fill(color)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(x: -offset, y: offset)
            }
        )
    }
}

struct BrutalistStroke: ViewModifier {
    let width: CGFloat

    init(width: CGFloat = 2) {
        self.width = width
    }

    func body(content: Content) -> some View {
        content.overlay(
            Rectangle()
                .stroke(Color.ampBlack, lineWidth: width)
        )
    }
}

extension View {
    @ViewBuilder
    func brutalistShadow(_ offset: BrutalistShadowOffset = .small, color: Color = .ampNavy, when condition: Bool = true) -> some View {
        if condition {
            modifier(BrutalistShadow(offset: offset, color: color))
        } else {
            self
        }
    }

    func brutalistStroke(width: CGFloat = 2) -> some View {
        modifier(BrutalistStroke(width: width))
    }

    // Invertible fill: replaces the static (background + stroke + shadow)
    // pattern for components that toggle between white+shadow (inactive)
    // and navy+no-shadow (active). Animates the navy rect from the shadow
    // offset onto the button while the white fill fades out — so the
    // inversion visually "slides in" from where the shadow was sitting.
    // Replaces:
    //   .background(isActive ? .ampNavy : .ampWhite)
    //   .brutalistStroke()
    //   .brutalistShadow(.small, when: !isActive)
    func brutalistInvertible(isActive: Bool, offset: BrutalistShadowOffset = .small) -> some View {
        modifier(BrutalistInvertible(isActive: isActive, offsetValue: offset.rawValue))
    }
}

// ButtonStyle for non-invertible brutalist buttons (BackButton,
// PlayAllBar, LyricsButton, ChromeButton, TransportButton prev/next/
// play-pause). Replaces the default `.buttonStyle(.plain)` plus inline
// background + stroke + shadow composition with a unified press-aware
// version:
//
// - Unpressed: navy rect at shadow offset, opaque fill on top, 2px stroke
// - Pressed:   navy rect slides to (0,0), hidden behind the fill. The
//              visible effect is the shadow retracting INTO the button —
//              consistent with the invertible animation where navy slides
//              onto the button, just without the fill fade.
//
// This also kills SwiftUI's default opacity-on-press behaviour that was
// letting the navy shadow bleed through as a washed-out blue tint.

struct BrutalistButtonStyle: ButtonStyle {
    let offset: BrutalistShadowOffset
    let fillColor: Color

    init(offset: BrutalistShadowOffset = .small, fillColor: Color = .ampWhite) {
        self.offset = offset
        self.fillColor = fillColor
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                GeometryReader { geo in
                    ZStack {
                        Rectangle()
                            .fill(Color.ampNavy)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .offset(
                                x: configuration.isPressed ? 0 : -offset.rawValue,
                                y: configuration.isPressed ? 0 : offset.rawValue
                            )
                        Rectangle()
                            .fill(fillColor)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
                }
            }
            .overlay(Rectangle().stroke(Color.ampBlack, lineWidth: 2))
    }
}

struct BrutalistInvertible: ViewModifier {
    let isActive: Bool
    let offsetValue: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle()
                        .fill(Color.ampNavy)
                        .offset(
                            x: isActive ? 0 : -offsetValue,
                            y: isActive ? 0 : offsetValue
                        )
                    Rectangle()
                        .fill(Color.ampWhite)
                        .opacity(isActive ? 0 : 1)
                }
                .animation(.easeInOut(duration: 0.25), value: isActive)
            }
            .overlay(Rectangle().stroke(Color.ampBlack, lineWidth: 2))
    }
}

#Preview("Brutalist primitives") {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        VStack(spacing: 32) {
            Rectangle()
                .fill(Color.ampWhite)
                .frame(width: 120, height: 44)
                .brutalistShadow(.small)
                .brutalistStroke()
                .overlay(Text("small 4px").font(.metadata))

            Rectangle()
                .fill(Color.ampGreen)
                .frame(width: 240, height: 44)
                .brutalistShadow(.large)
                .brutalistStroke()
                .overlay(Text("large 6px").font(.playAllBarTitle))

            Rectangle()
                .fill(Color.ampNavy)
                .frame(width: 120, height: 44)
                .brutalistStroke()
                .overlay(Text("active (no shadow)").font(.metadata).foregroundStyle(.white))
        }
    }
}
