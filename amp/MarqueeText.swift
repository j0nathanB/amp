import SwiftUI

// Marquee text that scrolls horizontally when content overflows its
// container. Scroll pattern: pause → scroll to end → pause → scroll back
// → pause → repeat.
//
// Implementation uses a single Task scoped to the view's identity.
// Every state transition (text change, container resize, view disappear)
// cancels the Task and starts a fresh one. Every await checks
// Task.isCancelled so no stale animation fires after cancellation —
// which is what caused the bugs in the legacy asyncAfter-chain version.

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    // Speed and pauses are tunable; defaults feel iTunes-ish.
    var pixelsPerSecond: CGFloat = 30
    var pauseSeconds: Double = 1.5
    var edgePadding: CGFloat = 20

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
            .onChange(of: text) { _, _ in
                // Don't restart with the stale textWidth from the previous
                // string — that misclassifies a short new text as overflowing
                // and starts a scroll that only stops once onPreferenceChange
                // delivers the new measurement. Invalidate the width and let
                // onPreferenceChange drive the restart.
                cancel()
                offset = 0
                textWidth = 0
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
        // textWidth==0 means "not yet measured" (initial frame, or just-changed
        // text before the new preference fires). Render at the leading edge so
        // we don't flash text into the container's center.
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
