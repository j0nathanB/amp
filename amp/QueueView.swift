import SwiftUI
import MediaPlayer

// Spec §7.3: Queue tab root. Yellow QUEUE title block with track count,
// Loop + Shuffle toggles below (spec amendment from the Now Playing
// transport migration), then a list of TrackRows with position numbers.
// Current track renders as the navy-inverted variant with equalizer bars.
//
// Phase G ships the layout + interactions. Spec §8.4's bi-directional
// sticky current-row pinning and blue overflow bars are a follow-up pass;
// they need careful scroll-offset tracking and are orthogonal to the main
// rebuild.

struct QueueView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var nav = NavigationService.shared

    var body: some View {
        VStack(spacing: 0) {
            chrome
            trackList
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 16) {
            ViewTitleBlock("QUEUE", trailing: trackCountLabel)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                TransportButton(kind: .loop, isActive: audioPlayer.isLooped) {
                    audioPlayer.toggleLoop()
                }
                TransportButton(kind: .shuffle, isActive: audioPlayer.isShuffled) {
                    audioPlayer.toggleShuffle()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private var trackCountLabel: String? {
        let count = audioPlayer.playbackQueue.trackIDs.count
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "track" : "tracks")"
    }

    // MARK: - Track list

    @ViewBuilder
    private var trackList: some View {
        if audioPlayer.playbackQueue.trackIDs.isEmpty {
            VStack {
                Spacer()
                Text("Queue is empty.")
                    .font(.metadata)
                    .foregroundStyle(Color.ampMutedText)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(audioPlayer.playbackQueue.trackIDs.enumerated()), id: \.offset) { index, trackID in
                            QueueRow(
                                index: index,
                                trackID: trackID,
                                isCurrent: index == audioPlayer.currentIndex
                            ) {
                                audioPlayer.playTrack(at: index)
                            }
                            .id(index)
                        }
                    }
                }
                .onAppear { scrollToCurrent(proxy: proxy, animated: false) }
                .onChange(of: audioPlayer.currentIndex) { _, _ in
                    scrollToCurrent(proxy: proxy, animated: true)
                }
            }
        }
    }

    private func scrollToCurrent(proxy: ScrollViewProxy, animated: Bool) {
        guard let index = audioPlayer.playbackQueue.currentIndex else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(index, anchor: .center)
            }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if let context = playingFromText {
            Text(context)
                .font(.metadata)
                .foregroundStyle(Color.ampMutedText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.ampWhite)
        }
    }

    // Phase G approximates queue context from the current track's album.
    // This is right when the queue was started from an album and wrong when
    // it's a cross-album mix — can be upgraded once we track queue provenance
    // in QueueManagerService.
    private var playingFromText: String? {
        guard let album = audioPlayer.currentTrack?.album, !album.isEmpty else { return nil }
        return "PLAYING FROM \(album.uppercased())"
    }
}

// MARK: - QueueRow (wraps TrackRow with async song hydration)

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
            duration: formatDuration(duration),
            isCurrent: isCurrent,
            onTap: onTap
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
