import SwiftUI

// Spec §5.10: parameterized transport button for BT / Prev / Play/Pause / Next / Loop.
// BT + Loop invert to navy when active. PlayPause stays ampGreen (never inverts).
// Prev/Next are momentary — no active state.

enum TransportKind {
    case bluetooth, previous, playPause, next, loop, shuffle

    var size: CGFloat {
        switch self {
        case .playPause: 82
        case .previous, .next: 56
        case .bluetooth, .loop, .shuffle: 44
        }
    }

    var shadowOffset: BrutalistShadowOffset {
        self == .playPause ? .large : .small
    }

    var supportsInversion: Bool {
        self == .bluetooth || self == .loop || self == .shuffle
    }
}

struct TransportButton: View {
    let kind: TransportKind
    var isActive: Bool = false
    var isPlaying: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if kind.supportsInversion {
                    icon
                        .frame(width: kind.size, height: kind.size)
                        .brutalistInvertible(isActive: isActive, offset: kind.shadowOffset)
                } else {
                    icon
                        .frame(width: kind.size, height: kind.size)
                        .background(backgroundColor)
                        .brutalistStroke()
                        .brutalistShadow(kind.shadowOffset)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    private var inverted: Bool {
        kind.supportsInversion && isActive
    }

    private var backgroundColor: Color {
        switch kind {
        case .playPause: .ampGreen
        default: inverted ? .ampNavy : .ampWhite
        }
    }

    private var iconColor: Color {
        inverted ? .ampWhite : .ampBlack
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .bluetooth: BluetoothGlyph(color: iconColor)
        case .previous: SkipGlyph(direction: .left, color: iconColor)
        case .playPause: PlayPauseGlyph(isPlaying: isPlaying)
        case .next: SkipGlyph(direction: .right, color: iconColor)
        case .loop: LoopGlyph(color: iconColor)
        case .shuffle: ShuffleGlyph(color: iconColor)
        }
    }

    private var accessibilityText: String {
        switch kind {
        case .bluetooth: isActive ? "Bluetooth connected" : "Bluetooth"
        case .previous: "Previous track"
        case .playPause: isPlaying ? "Pause" : "Play"
        case .next: "Next track"
        case .loop: isActive ? "Loop on" : "Loop off"
        case .shuffle: isActive ? "Shuffle on" : "Shuffle off"
        }
    }
}

private struct PlayPauseGlyph: View {
    let isPlaying: Bool
    var body: some View {
        if isPlaying {
            HStack(spacing: 10) {
                Rectangle().fill(Color.ampBlack).frame(width: 9, height: 34)
                Rectangle().fill(Color.ampBlack).frame(width: 9, height: 34)
            }
        } else {
            Triangle(pointing: .right)
                .fill(Color.ampBlack)
                .frame(width: 22, height: 26)
                .offset(x: 3, y: 0) // optical centering for a triangle
        }
    }
}

private struct SkipGlyph: View {
    enum Direction { case left, right }
    let direction: Direction
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            if direction == .left {
                Rectangle().fill(color).frame(width: 3, height: 20)
                Triangle(pointing: .left).fill(color).frame(width: 14, height: 20)
            } else {
                Triangle(pointing: .right).fill(color).frame(width: 14, height: 20)
                Rectangle().fill(color).frame(width: 3, height: 20)
            }
        }
    }
}

private struct BluetoothGlyph: View {
    let color: Color
    var body: some View {
        BluetoothShape()
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 14, height: 22)
    }
}

private struct BluetoothShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = CGPoint(x: rect.midX, y: rect.minY)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.75)
        let topLeft = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.75)

        // Upper triangle: top → topRight → mid-left
        p.move(to: top)
        p.addLine(to: topRight)
        p.addLine(to: bottomLeft)
        // Full stem: bottom-left → bottom
        p.move(to: topLeft)
        p.addLine(to: bottomRight)
        p.addLine(to: bottom)
        p.addLine(to: top)
        return p
    }
}

private struct LoopGlyph: View {
    let color: Color
    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(color)
    }
}

private struct ShuffleGlyph: View {
    let color: Color
    var body: some View {
        Image(systemName: "shuffle")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(color)
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                TransportButton(kind: .bluetooth, action: {})
                TransportButton(kind: .bluetooth, isActive: true, action: {})
            }
            HStack(spacing: 12) {
                TransportButton(kind: .previous, action: {})
                TransportButton(kind: .playPause, isPlaying: false, action: {})
                TransportButton(kind: .playPause, isPlaying: true, action: {})
                TransportButton(kind: .next, action: {})
            }
            HStack(spacing: 12) {
                TransportButton(kind: .loop, action: {})
                TransportButton(kind: .loop, isActive: true, action: {})
            }
        }
    }
}
