import SwiftUI

// Marquee text that scrolls horizontally when content overflows its
// container. Scroll pattern: pause → scroll to end → pause → scroll back
// → pause → repeat.
//
// MarqueeText is a thin wrapper that gives MarqueeContent a fresh identity
// per text via .id(text). On every text change SwiftUI tears down the old
// MarqueeContent (firing onDisappear → cancel) and brings up a new one with
// reset @State. This sidesteps the rapid prev/next bugs where stale
// measurement or animation state from a prior title would leak into the
// next one — including the dedupe case where bouncing back to a recently
// shown title would fail to refire onPreferenceChange and leave the
// scroller stuck.
//
// The scroll is driven by a single Task. Every await checks
// Task.isCancelled so no stale animation fires after cancellation —
// which is what caused the bugs in the legacy asyncAfter-chain version.

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    var pixelsPerSecond: CGFloat = 30
    var pauseSeconds: Double = 1.5
    var edgePadding: CGFloat = 20

    var body: some View {
        MarqueeContent(
            text: text,
            font: font,
            color: color,
            pixelsPerSecond: pixelsPerSecond,
            pauseSeconds: pauseSeconds,
            edgePadding: edgePadding
        )
        .id(text)
    }
}

private struct MarqueeContent: View {
    let text: String
    let font: Font
    let color: Color
    let pixelsPerSecond: CGFloat
    let pauseSeconds: Double
    let edgePadding: CGFloat

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        GeometryReader { textGeo in
                            Color.clear.preference(
                                key: MarqueeTextWidthKey.self,
                                value: textGeo.size.width
                            )
                        }
                    )
                    .offset(x: displayOffset(containerWidth: geo.size.width))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .onPreferenceChange(MarqueeTextWidthKey.self) { newWidth in
                if textWidth != newWidth {
                    textWidth = newWidth
                    restart()
                }
            }
            .onChange(of: geo.size.width) { _, newWidth in
                if containerWidth != newWidth {
                    containerWidth = newWidth
                    restart()
                }
            }
            .onAppear {
                containerWidth = geo.size.width
                restart()
            }
            .onDisappear {
                cancel()
            }
        }
    }

    private var overflow: CGFloat {
        max(0, textWidth - containerWidth)
    }

    // When text fits, center it. When overflowing, apply the animated offset.
    private func displayOffset(containerWidth: CGFloat) -> CGFloat {
        // textWidth==0 is the pre-measurement frame: render at the leading
        // edge so we don't briefly flash text into the container's center
        // before snapping it back once the real width arrives.
        guard textWidth > 0 else { return 0 }
        if overflow > 0 {
            return offset
        }
        return max(0, (containerWidth - textWidth) / 2)
    }

    private func cancel() {
        scrollTask?.cancel()
        scrollTask = nil
    }

    private func restart() {
        cancel()
        offset = 0

        guard overflow > 0, containerWidth > 0 else { return }

        let distance = overflow + edgePadding
        let duration = Double(distance / pixelsPerSecond)

        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(pauseSeconds))
            guard !Task.isCancelled else { return }

            while !Task.isCancelled {
                withAnimation(.linear(duration: duration)) {
                    offset = -distance
                }
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }

                try? await Task.sleep(for: .seconds(pauseSeconds))
                guard !Task.isCancelled else { return }

                withAnimation(.linear(duration: duration)) {
                    offset = 0
                }
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }

                try? await Task.sleep(for: .seconds(pauseSeconds))
            }
        }
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
