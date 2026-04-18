import SwiftUI

// 12pt linear gradient strips at the top and bottom edges of a scroll
// container, visible only when content is actually clipped beyond that
// edge. Apply to any `ScrollView` or `List` that could scroll. Queue
// renders its own inline version since pin-state and bar presence are
// interlocked there (spec §8.4).
//
// Usage:
//   ScrollView { ... }.overflowGradientBars()
//
// Uses iOS 17+'s onScrollGeometryChange to track offset / viewport /
// content size without needing a parent-supplied ScrollViewReader.

private let overflowBarHeight: CGFloat = 12
private let overflowBarColorName = "AccentSkyBlue"

struct OverflowGradientBars: ViewModifier {
    // Single Equatable @State so onScrollGeometryChange only triggers a
    // re-render when the snapshot actually changes. Writing three separate
    // @State vars per scroll frame reliably triggered SwiftUI's
    // "OnScrollGeometryChange Modifier tried to update multiple times per
    // frame" fault.
    @State private var snapshot = ScrollSnapshot(offsetY: 0, viewport: 0, content: 0)

    func body(content: Content) -> some View {
        ZStack {
            content
                .onScrollGeometryChange(for: ScrollSnapshot.self, of: { geo in
                    ScrollSnapshot(
                        offsetY: geo.contentOffset.y,
                        viewport: geo.containerSize.height,
                        content: geo.contentSize.height
                    )
                }, action: { _, snap in
                    snapshot = snap
                })

            VStack(spacing: 0) {
                if showTopBar {
                    topBar
                }
                Spacer(minLength: 0)
                if showBottomBar {
                    bottomBar
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var showTopBar: Bool {
        snapshot.offsetY > 4
    }

    private var showBottomBar: Bool {
        snapshot.content > 0 && (snapshot.offsetY + snapshot.viewport + 4) < snapshot.content
    }

    private var topBar: some View {
        LinearGradient(
            colors: [Color(overflowBarColorName).opacity(0.9), Color(overflowBarColorName).opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: overflowBarHeight)
    }

    private var bottomBar: some View {
        LinearGradient(
            colors: [Color(overflowBarColorName).opacity(0), Color(overflowBarColorName).opacity(0.9)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: overflowBarHeight)
    }
}

private struct ScrollSnapshot: Equatable {
    let offsetY: CGFloat
    let viewport: CGFloat
    let content: CGFloat
}

extension View {
    func overflowGradientBars() -> some View {
        modifier(OverflowGradientBars())
    }
}
