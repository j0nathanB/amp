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
    @State private var scrollY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

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
                    scrollY = snap.offsetY
                    viewportHeight = snap.viewport
                    contentHeight = snap.content
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
        scrollY > 4
    }

    private var showBottomBar: Bool {
        contentHeight > 0 && (scrollY + viewportHeight + 4) < contentHeight
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
