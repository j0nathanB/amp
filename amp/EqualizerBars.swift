import SwiftUI

// Spec §8.3: 3 vertical bars (4px wide each), heights oscillate between ~8
// and ~28px on a staggered sine wave (different phase per bar), period ~1.2s.
// Used by the navy-inverted TrackRow variant and by Queue pinning (§8.4).

struct EqualizerBars: View {
    var color: Color = .ampWhite
    var barWidth: CGFloat = 4
    var gap: CGFloat = 3
    var maxHeight: CGFloat = 28
    var isAnimating: Bool = true

    // Static height used when not animating — "three little lines"
    // equal-height stubs signalling "this is the current track but paused".
    private let pausedHeight: CGFloat = 8

    var body: some View {
        Group {
            if isAnimating {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    barStack(
                        heights: [
                            wave(t, phase: 0.00),
                            wave(t, phase: 0.33),
                            wave(t, phase: 0.66)
                        ]
                    )
                }
            } else {
                barStack(heights: [pausedHeight, pausedHeight, pausedHeight])
            }
        }
        .frame(width: barWidth * 3 + gap * 2, height: maxHeight)
        .accessibilityHidden(true)
    }

    private func barStack(heights: [CGFloat]) -> some View {
        HStack(alignment: .center, spacing: gap) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Rectangle()
                    .fill(color)
                    .frame(width: barWidth, height: h)
            }
        }
    }

    private func wave(_ t: TimeInterval, phase: Double) -> CGFloat {
        let period: Double = 1.2
        let x = (t / period + phase) * 2 * .pi
        let sine = (sin(x) + 1) / 2 // 0..1
        return 8 + CGFloat(sine) * (maxHeight - 8)
    }
}

#Preview {
    ZStack {
        Color.ampNavy.ignoresSafeArea()
        EqualizerBars()
    }
}
