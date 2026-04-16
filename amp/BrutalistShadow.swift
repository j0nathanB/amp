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
