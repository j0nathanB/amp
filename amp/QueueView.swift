import SwiftUI
import MediaPlayer

// Spec §7.3 + §8.4: Queue tab root with bi-directional sticky current-row
// pinning and blue-gradient overflow bars.
//
// Pin states (§8.4):
// - .none         current row is fully inside the viewport; blue bars
//                 show at either edge when content is clipped
// - .pinnedTop    current row's top edge has reached the viewport top —
//                 it sticks to the top edge while the queue scrolls
//                 behind it; top blue bar is suppressed in its place
// - .pinnedBottom current row's bottom edge has reached the viewport
//                 bottom — it sticks to the bottom; bottom blue bar is
//                 suppressed in its place
//
// Pinning engages the moment the row would otherwise start to clip at
// the edge — not when it's fully off-screen. Engaging late produced a
// visible jank: the in-list row would clip away, then the pin would
// snap in at the edge as a full row.
//
// Geometry: rows before/after current are rowHeight tall, the navy-
// inverted current row is currentRowHeight tall. `onScrollGeometryChange`
// (iOS 17+) feeds us scrollY / viewport / content.

private let rowHeight: CGFloat = 72            // TrackRow prominent regular + artist
private let currentRowHeight: CGFloat = 84     // TrackRow prominent navy-inverted + artist
private let overflowBarHeight: CGFloat = 12

struct QueueView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var nav = NavigationService.shared

    // Single Equatable @State so onScrollGeometryChange only triggers a
    // re-render when the snapshot actually changes — avoids SwiftUI's
    // "OnScrollGeometryChange Modifier tried to update multiple times per
    // frame" fault.
    @State private var snapshot = ScrollSnapshot(offsetY: 0, viewport: 0, content: 0)

    // MainTabView keeps every tab mounted (ZStack + opacity), so
    // proxy.scrollTo on a hidden tab is a no-op. When the pin-default
    // setting flips while we're not visible, stash the request and
    // replay it the moment the Queue tab becomes active.
    @State private var pendingPinReset: Bool = false

    // Temporarily forces pinState to .none so the in-list current row
    // renders as a real navy QueueRow (not the Color.clear placeholder).
    // proxy.scrollTo targets the view with .id(index) — when that view
    // is Color.clear, scrollTo doesn't reliably reposition. We flip this
    // on, scroll, wait for the snapshot to update, then flip it off so
    // the overlay re-engages from the new scroll position.
    @State private var bypassPin: Bool = false
    private var scrollY: CGFloat { snapshot.offsetY }
    private var viewportHeight: CGFloat { snapshot.viewport }
    private var contentHeight: CGFloat { snapshot.content }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            trackListArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack(spacing: 12) {
            ViewTitleBlock("QUEUE", trailing: trackCountLabel)
            TransportButton(kind: .loop, isActive: audioPlayer.isLooped) {
                audioPlayer.toggleLoop()
            }
            TransportButton(kind: .shuffle, isActive: audioPlayer.isShuffled) {
                audioPlayer.toggleShuffle()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private var trackCountLabel: String? {
        let count = audioPlayer.playbackQueue.trackIDs.count
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "\ntrack" : "\ntracks")"
    }

    // MARK: - Track list area (scroll + pin + overflow overlays)

    @ViewBuilder
    private var trackListArea: some View {
        if audioPlayer.playbackQueue.trackIDs.isEmpty {
            // Distinguish "still restoring from disk" from "genuinely
            // empty queue" — the 489ms queue-restore window was flashing
            // the "Queue is empty" message on every cold launch.
            if audioPlayer.queueInitialLoadCompleted {
                emptyState
            } else {
                loadingState
            }
        } else {
            ZStack {
                scrollingList
                overflowOverlay
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Queue is empty.")
                .font(.metadata)
                .foregroundStyle(Color.ampMutedText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        EqualizerBars()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scrollingList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Range<Int> directly — no Array(enumerated()) allocation.
                    // The old form rebuilt a 23k-tuple array on every body
                    // re-render, which fires on every audioPlayer.playbackTime
                    // @Published tick during playback.
                    ForEach(audioPlayer.playbackQueue.trackIDs.indices, id: \.self) { index in
                        let trackID = audioPlayer.playbackQueue.trackIDs[index]
                        let isCurrent = index == audioPlayer.currentIndex

                        if isCurrent && pinState != .none {
                            // Pin overlay is rendering this row at the
                            // viewport edge. Reserve vertical space so
                            // surrounding rows don't shift, but don't
                            // paint navy here — there must only ever be
                            // one highlighted row visible at a time.
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: currentRowHeight, maxHeight: currentRowHeight)
                                .id(index)
                        } else {
                            QueueRow(
                                index: index,
                                trackID: trackID,
                                isCurrent: isCurrent
                            ) {
                                handleTap(at: index)
                            }
                            .id(index)
                        }
                    }
                }
            }
            .onScrollGeometryChange(for: ScrollSnapshot.self, of: { geo in
                ScrollSnapshot(
                    offsetY: geo.contentOffset.y,
                    viewport: geo.containerSize.height,
                    content: geo.contentSize.height
                )
            }, action: { _, snap in
                snapshot = snap
            })
            .onAppear { scrollToCurrent(proxy: proxy, animated: false) }
            .onChange(of: audioPlayer.currentIndex) { _, _ in
                scrollToCurrent(proxy: proxy, animated: true)
            }
            .onChange(of: settings.queuePinDefaultTop) { _, _ in
                if nav.selectedTab == .queue {
                    performPinReset(proxy: proxy)
                } else {
                    // Tab is hidden — proxy.scrollTo would silently fail.
                    // Stash and replay when the user comes back.
                    pendingPinReset = true
                }
            }
            .onChange(of: nav.selectedTab) { _, newTab in
                if newTab == .queue && pendingPinReset {
                    performPinReset(proxy: proxy)
                    pendingPinReset = false
                }
            }
        }
    }

    // Overlay stack: pinned current row OR overflow bar at each edge.
    // Spec: the pinned row replaces the blue bar on its edge; never both
    // on the same edge.
    private var overflowOverlay: some View {
        VStack(spacing: 0) {
            // Top edge
            if pinState == .pinnedTop {
                pinnedCurrentRow
            } else if showTopBar {
                topOverflowBar
            }

            Spacer(minLength: 0)

            // Bottom edge
            if pinState == .pinnedBottom {
                pinnedCurrentRow
            } else if showBottomBar {
                bottomOverflowBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(pinState != .none)
    }

    // MARK: - Pin state + overflow flags

    private enum PinState { case none, pinnedTop, pinnedBottom }

    private var pinState: PinState {
        if bypassPin { return .none }
        let i = audioPlayer.currentIndex
        guard i >= 0 else { return .none }
        guard viewportHeight > 0 else { return .none }
        let startY = CGFloat(i) * rowHeight
        let endY = startY + currentRowHeight
        if startY <= scrollY { return .pinnedTop }
        if endY >= scrollY + viewportHeight { return .pinnedBottom }
        return .none
    }

    private var showTopBar: Bool {
        scrollY > 4
    }

    private var showBottomBar: Bool {
        contentHeight > 0 && (scrollY + viewportHeight + 4) < contentHeight
    }

    // MARK: - Overlay views

    @ViewBuilder
    private var pinnedCurrentRow: some View {
        let index = audioPlayer.currentIndex
        if index >= 0, let trackID = audioPlayer.playbackQueue.trackIDs[safe: index] {
            QueueRow(
                index: index,
                trackID: trackID,
                isCurrent: true
            ) {
                handleTap(at: index)
            }
        }
    }

    private var topOverflowBar: some View {
        LinearGradient(
            colors: [Color("AccentSkyBlue").opacity(0.9), Color("AccentSkyBlue").opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: overflowBarHeight)
        .allowsHitTesting(false)
    }

    private var bottomOverflowBar: some View {
        LinearGradient(
            colors: [Color("AccentSkyBlue").opacity(0), Color("AccentSkyBlue").opacity(0.9)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: overflowBarHeight)
        .allowsHitTesting(false)
    }

    // MARK: - Interactions

    private func handleTap(at index: Int) {
        if index == audioPlayer.currentIndex {
            audioPlayer.playPause()
        } else {
            audioPlayer.playTrack(at: index)
        }
    }

    // Destroy the pin overlay, scroll, then regenerate. The in-list
    // current row needs to be a real QueueRow (not Color.clear) for
    // proxy.scrollTo to reliably anchor it; once the scroll settles
    // and snapshot.offsetY catches up, the overlay re-engages from
    // the new pinState.
    private func performPinReset(proxy: ScrollViewProxy) {
        bypassPin = true
        DispatchQueue.main.async {
            scrollToCurrent(proxy: proxy, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                bypassPin = false
            }
        }
    }

    private func scrollToCurrent(proxy: ScrollViewProxy, animated: Bool) {
        guard let index = audioPlayer.playbackQueue.currentIndex else { return }
        let anchor: UnitPoint = settings.queuePinDefaultTop ? .top : .bottom
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(index, anchor: anchor)
            }
        } else {
            proxy.scrollTo(index, anchor: anchor)
        }
    }
}

// MARK: - Scroll snapshot

private struct ScrollSnapshot: Equatable {
    let offsetY: CGFloat
    let viewport: CGFloat
    let content: CGFloat
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - QueueRow (wraps TrackRow with async song + duration hydration)

private struct QueueRow: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    let index: Int
    let trackID: MPMediaEntityPersistentID
    let isCurrent: Bool
    let onTap: () -> Void

    // Fallbacks populated only on cache miss (first launch before the
    // search index has built). Steady-state rendering reads cachedSong /
    // cachedDuration directly from the in-memory index — no state, no
    // async, no spinner flash.
    @State private var fallbackSong: Song?
    @State private var fallbackDuration: TimeInterval?

    private var song: Song? {
        LibraryService.shared.cachedSong(by: trackID) ?? fallbackSong
    }

    private var duration: TimeInterval {
        LibraryService.shared.cachedDuration(forTrack: trackID)
            ?? fallbackDuration ?? 0
    }

    var body: some View {
        TrackRow(
            position: "\(index + 1)",
            title: song?.title ?? "…",
            artist: song?.artist,
            duration: formatDuration(duration),
            isCurrent: isCurrent,
            prominent: true,
            playbackState: isCurrent ? TrackRow.PlaybackState(
                isPlaying: audioPlayer.isPlaying,
                elapsed: audioPlayer.playbackTime
            ) : nil,
            onTap: onTap,
            onLongPress: {
                NavigationService.shared.navigateToAlbum(forTrack: trackID)
            }
        )
        .task(id: trackID) {
            // Cache hit: nothing to do — the computed properties above
            // already delivered real data on first render.
            if LibraryService.shared.cachedSong(by: trackID) != nil { return }
            // Cache miss (first launch window before index build finishes):
            // async fallback via MPMediaQuery.
            let hydrated = await Task.detached(priority: .userInitiated) {
                (
                    song: LibraryService.shared.getSong(by: trackID),
                    duration: LibraryService.shared.getDuration(forTrack: trackID)
                )
            }.value
            self.fallbackSong = hydrated.song
            self.fallbackDuration = hydrated.duration
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
