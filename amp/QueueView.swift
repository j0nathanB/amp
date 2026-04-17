import SwiftUI
import MediaPlayer

// Spec §7.3 + §8.4: Queue tab root with bi-directional sticky current-row
// pinning and blue-gradient overflow bars.
//
// Pin states (§8.4):
// - .none         current row is visible in the viewport; blue bars show
//                 at either edge when content is clipped
// - .pinnedTop    scrolled past the current row — it sticks to the top of
//                 the viewport; top blue bar is suppressed in its place
// - .pinnedBottom scrolled before the current row — it sticks to the
//                 bottom; bottom blue bar is suppressed in its place
//
// Geometry: rows before/after current are rowHeight tall, the navy-
// inverted current row is currentRowHeight tall. `onScrollGeometryChange`
// (iOS 17+) feeds us scrollY / viewport / content.

private let rowHeight: CGFloat = 72            // TrackRow prominent regular + artist
private let currentRowHeight: CGFloat = 84     // TrackRow prominent navy-inverted + artist
private let overflowBarHeight: CGFloat = 12

struct QueueView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    @State private var scrollY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

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
            emptyState
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

    private var scrollingList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(audioPlayer.playbackQueue.trackIDs.enumerated()), id: \.offset) { index, trackID in
                        QueueRow(
                            index: index,
                            trackID: trackID,
                            isCurrent: index == audioPlayer.currentIndex
                        ) {
                            handleTap(at: index)
                        }
                        .id(index)
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
                scrollY = snap.offsetY
                viewportHeight = snap.viewport
                contentHeight = snap.content
            })
            .onAppear { scrollToCurrent(proxy: proxy, animated: false) }
            .onChange(of: audioPlayer.currentIndex) { _, _ in
                scrollToCurrent(proxy: proxy, animated: true)
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
        let i = audioPlayer.currentIndex
        guard i >= 0 else { return .none }
        guard viewportHeight > 0 else { return .none }
        let startY = CGFloat(i) * rowHeight
        let endY = startY + currentRowHeight
        if endY <= scrollY { return .pinnedTop }
        if startY >= scrollY + viewportHeight { return .pinnedBottom }
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

    private func scrollToCurrent(proxy: ScrollViewProxy, animated: Bool) {
        guard let index = audioPlayer.playbackQueue.currentIndex else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(index, anchor: .top)
            }
        } else {
            proxy.scrollTo(index, anchor: .top)
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
    let index: Int
    let trackID: MPMediaEntityPersistentID
    let isCurrent: Bool
    let onTap: () -> Void

    @State private var song: Song?
    @State private var duration: TimeInterval = 0

    var body: some View {
        TrackRow(
            position: "\(index + 1)",
            title: song?.title ?? "…",
            artist: song?.artist,
            duration: formatDuration(duration),
            isCurrent: isCurrent,
            prominent: true,
            onTap: onTap,
            onLongPress: {
                NavigationService.shared.navigateToAlbum(forTrack: trackID)
            }
        )
        .task(id: trackID) {
            let hydrated = await Task.detached(priority: .userInitiated) {
                (
                    song: LibraryService.shared.getSong(by: trackID),
                    duration: LibraryService.shared.getDuration(forTrack: trackID)
                )
            }.value
            self.song = hydrated.song
            self.duration = hydrated.duration
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
