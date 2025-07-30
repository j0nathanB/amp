import SwiftUI

struct QueueView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        NavigationStack {
            Group {
                if audioPlayer.playbackQueue.isEmpty {
                    Text("The queue is empty.")
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(0..<audioPlayer.playbackQueue.count, id: \.self) { index in
                                LazyQueueItemView(index: index)
                                    .id("\(audioPlayer.queueVersion)-\(index)") // Force refresh when queue changes
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("Up Next").font(Theme.titleFont).foregroundColor(Theme.primaryText)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !audioPlayer.playbackQueue.isEmpty {
                        Button("Shuffle Queue") {
                            audioPlayer.shuffleCurrentQueue()
                        }
                        .foregroundColor(Theme.accentPink)
                        .font(Theme.bodyFont)
                    }
                }
            }
        }
    }
}

// Lazy-loading queue item view
private struct LazyQueueItemView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    let index: Int
    @State private var song: Song?
    @GestureState private var isPressed = false

    var body: some View {
        Group {
            if let song = song {
                ListItemView(
                    title: song.title,
                    subtitle: song.artist,
                    isPlaying: index == audioPlayer.playbackQueue.currentIndex,
                    detail: song.album,
                    playPauseAction: {
                        audioPlayer.playPause()
                    },
                    isPressed: isPressed
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isPressed) { _, state, _ in
                            state = true
                        }
                        .onEnded { _ in
                            audioPlayer.playTrack(at: index)
                        }
                )
            } else {
                // Loading placeholder
                ListItemView(
                    title: "Loading...",
                    subtitle: "",
                    isPlaying: false,
                    detail: "",
                    playPauseAction: {},
                    isPressed: false
                )
            }
        }
        .onAppear {
            loadSong()
        }
    }
    
    private func loadSong() {
        Task {
            // Load song on background thread
            if let trackID = audioPlayer.playbackQueue.getTrackID(at: index),
               let loadedSong = LibraryService.shared.getSong(by: trackID) {
                await MainActor.run {
                    self.song = loadedSong
                }
            }
        }
    }
}
