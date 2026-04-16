import SwiftUI
import MediaPlayer

// Spec §7.3 + Queue amendments: Queue tab root. Chrome row holds the yellow
// QUEUE title block (with trailing "N tracks") plus Loop + Shuffle toggles
// inline — same pattern as Library's chrome. Loop here is QUEUE loop;
// Now Playing's Loop is SONG loop (two distinct toggles).
//
// Track rows show title + artist (multi-album queues need the artist line).
// Tapping the current row toggles play/pause; tapping any other row jumps
// playback to that track. Neither switches tabs — Queue is its own context
// for browsing and bouncing around playback.
//
// Spec §8.4's bi-directional sticky pinning + blue overflow bars are a
// follow-up pass.

struct QueueView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        VStack(spacing: 0) {
            chrome
            trackList
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
                                isCurrent: index == audioPlayer.currentIndex,
                                isPlaying: audioPlayer.isPlaying
                            ) {
                                handleTap(at: index)
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

// MARK: - QueueRow (wraps TrackRow with async song + duration hydration)

private struct QueueRow: View {
    let index: Int
    let trackID: MPMediaEntityPersistentID
    let isCurrent: Bool
    let isPlaying: Bool
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
            isPlaying: isPlaying,
            audioLevelProvider: isCurrent ? { AudioPlayerService.shared.currentAudioLevel } : nil,
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
