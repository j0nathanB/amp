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

    // When provided, bar heights follow live audio level. Each bar adds a
    // small per-bar wiggle so they don't move identically. True
    // low/mid/high banding would need an AVAudioEngine FFT tap — deferred.
    var levelProvider: (() -> Float)? = nil

    // Static height used when not animating — "three little lines"
    // equal-height stubs signalling "this is the current track but paused".
    private let pausedHeight: CGFloat = 8

    var body: some View {
        Group {
            if isAnimating {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let heights: [CGFloat] = {
                        if let provider = levelProvider {
                            let level = CGFloat(provider())
                            return [0.00, 0.33, 0.66].map { phase in
                                audioHeight(level: level, phase: phase, t: t)
                            }
                        } else {
                            return [0.00, 0.33, 0.66].map { sineHeight(t: t, phase: $0) }
                        }
                    }()
                    barStack(heights: heights)
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

    // Audio-level-driven height: base on live level, add a small per-bar
    // wiggle so the three bars don't move in lockstep.
    private func audioHeight(level: CGFloat, phase: Double, t: TimeInterval) -> CGFloat {
        let minH: CGFloat = 6
        let range = maxHeight - minH
        let wiggle = CGFloat(sin((t / 0.25 + phase) * 2 * .pi)) * 0.15
        let combined = max(0, min(1, level + wiggle))
        return minH + combined * range
    }

    // Sine fallback used when no levelProvider is supplied.
    private func sineHeight(t: TimeInterval, phase: Double) -> CGFloat {
        let period: Double = 1.2
        let x = (t / period + phase) * 2 * .pi
        let sine = (sin(x) + 1) / 2
        return 8 + CGFloat(sine) * (maxHeight - 8)
    }
}

#Preview {
    ZStack {
        Color.ampNavy.ignoresSafeArea()
        EqualizerBars()
    }
}
