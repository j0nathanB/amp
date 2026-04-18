import SwiftUI

// Three vertical bars whose heights oscillate on a staggered sine wave
// (different phase per bar, ~1.2s period). Originally spec §8.3's
// current-track indicator; removed in commit 5af1405 when the FFT audio
// metering work was reverted. Now reused as the Library tab loading
// indicator — same bars, no audio tap, just a decorative animation.
struct EqualizerBars: View {
    var color: Color = .ampBlack
    var barWidth: CGFloat = 4
    var gap: CGFloat = 3
    var maxHeight: CGFloat = 28

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let heights = [0.00, 0.33, 0.66].map { sineHeight(t: t, phase: $0) }
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                    Rectangle()
                        .fill(color)
                        .frame(width: barWidth, height: h)
                }
            }
        }
        .frame(width: barWidth * 3 + gap * 2, height: maxHeight)
        .accessibilityHidden(true)
    }

    private func sineHeight(t: TimeInterval, phase: Double) -> CGFloat {
        let period: Double = 1.2
        let x = (t / period + phase) * 2 * .pi
        let sine = (sin(x) + 1) / 2
        return 8 + CGFloat(sine) * (maxHeight - 8)
    }
}

#Preview {
    ZStack {
        Color.ampWhite.ignoresSafeArea()
        EqualizerBars()
    }
}
