import SwiftUI

// Marquee text that scrolls horizontally when content overflows its container.
// Pause → scroll to end → pause → scroll back → pause → repeat.
//
// Scroll is driven by TimelineView with offset computed from elapsed time
// against an `animationStart` reference. Time-derived offset means there is
// no detached CABasicAnimation on the layer that could outlive a text change;
// resetting animationStart is sufficient to start a fresh cycle.
//
// Container width is read live from GeometryReader. The width preference key
// carries the text it was measured for, so a same-pixel-width title swap still
// re-fires onPreferenceChange.

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    var pixelsPerSecond: CGFloat = 30
    var pauseSeconds: Double = 1.5
    var edgePadding: CGFloat = 20

    @State private var measurement: MarqueeMeasurement = .empty
    @State private var animationStart: Date = .now

    var body: some View {
        GeometryReader { geo in
            let containerWidth = geo.size.width
            let measuredWidth = measurement.text == text ? measurement.width : 0
            let overflow = max(0, measuredWidth - containerWidth)

            ZStack(alignment: .leading) {
                if overflow > 0 {
                    TimelineView(.animation) { context in
                        textBody
                            .offset(x: scrollOffset(
                                at: context.date,
                                distance: overflow + edgePadding
                            ))
                    }
                } else {
                    textBody
                        .offset(x: centeredOffset(
                            measuredWidth: measuredWidth,
                            containerWidth: containerWidth
                        ))
                }
            }
            .frame(width: containerWidth, height: geo.size.height, alignment: .leading)
            .clipped()
            .onPreferenceChange(MarqueeMeasurementKey.self) { new in
                guard new.text == text, measurement != new else { return }
                measurement = new
                animationStart = .now
            }
            .onChange(of: containerWidth) { _, _ in
                animationStart = .now
            }
        }
    }

    private var textBody: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { textGeo in
                    Color.clear.preference(
                        key: MarqueeMeasurementKey.self,
                        value: MarqueeMeasurement(text: text, width: textGeo.size.width)
                    )
                }
            )
    }

    private func centeredOffset(measuredWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        guard measuredWidth > 0 else { return 0 }
        return max(0, (containerWidth - measuredWidth) / 2)
    }

    private func scrollOffset(at date: Date, distance: CGFloat) -> CGFloat {
        let duration = Double(distance / pixelsPerSecond)
        let cycleLength = 2 * pauseSeconds + 2 * duration
        let elapsed = max(0, date.timeIntervalSince(animationStart))
        let phase = elapsed.truncatingRemainder(dividingBy: cycleLength)

        if phase < pauseSeconds {
            return 0
        }
        if phase < pauseSeconds + duration {
            let progress = (phase - pauseSeconds) / duration
            return -distance * CGFloat(progress)
        }
        if phase < 2 * pauseSeconds + duration {
            return -distance
        }
        let progress = (phase - 2 * pauseSeconds - duration) / duration
        return -distance * CGFloat(1 - progress)
    }
}

private struct MarqueeMeasurement: Equatable {
    let text: String
    let width: CGFloat

    static let empty = MarqueeMeasurement(text: "", width: 0)
}

private struct MarqueeMeasurementKey: PreferenceKey {
    static let defaultValue: MarqueeMeasurement = .empty
    static func reduce(value: inout MarqueeMeasurement, nextValue: () -> MarqueeMeasurement) {
        value = nextValue()
    }
}
