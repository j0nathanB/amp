import SwiftUI

struct QueueView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        NavigationStack {
            Group {
                // The view now directly checks the single 'queue' property
                if audioPlayer.playbackQueue.tracks.isEmpty {
                    Text("The queue is empty.")
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(audioPlayer.playbackQueue.tracks.enumerated()), id: \.element) { index, song in
                                QueueItemView(song: song, index: index)
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
                    if !audioPlayer.playbackQueue.tracks.isEmpty {
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

// The QueueItemView is also now simpler
private struct QueueItemView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    let song: Song
    let index: Int
    @GestureState private var isPressed = false

    var body: some View {
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
    }
}
