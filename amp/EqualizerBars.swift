import SwiftUI

// Spec §8.3: 3 vertical bars (4px wide each), heights oscillate between ~8
// and ~28px on a staggered sine wave (different phase per bar), period ~1.2s.
// Used by the navy-inverted TrackRow variant and by Queue pinning (§8.4).

struct EqualizerBars: View {
    var color: Color = .ampWhite
    var barWidth: CGFloat = 4
    var gap: CGFloat = 3
    var maxHeight: CGFloat = 28

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: gap) {
                bar(height: wave(t, phase: 0.00))
                bar(height: wave(t, phase: 0.33))
                bar(height: wave(t, phase: 0.66))
            }
            .frame(width: barWidth * 3 + gap * 2, height: maxHeight)
        }
        .accessibilityHidden(true)
    }

    private func bar(height: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: barWidth, height: height)
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
