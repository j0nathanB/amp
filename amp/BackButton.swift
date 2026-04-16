import SwiftUI

// Spec §5.1: 44×44 white fill, 4px navy shadow, 2px black stroke.
// Left-pointing chevron, stroke-width 2.5, round linecaps/linejoins, ~14×22 centered.

struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Chevron()
                .stroke(
                    Color.ampBlack,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 12, height: 22)
                .frame(width: 44, height: 44)
                .background(Color.ampWhite)
                .brutalistStroke()
                .brutalistShadow(.small)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}

private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        BackButton(action: {})
    }
}
