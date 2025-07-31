import SwiftUI
import MediaPlayer

// Singleton to manage loaded songs and prevent re-loading
class QueueSongCache: ObservableObject {
    static let shared = QueueSongCache()
    private var loadedSongs: [MPMediaEntityPersistentID: Song] = [:]
    private var currentQueueVersion: Int = -1
    
    private init() {}
    
    func getSong(trackID: MPMediaEntityPersistentID) -> Song? {
        return loadedSongs[trackID]
    }
    
    func setSong(_ song: Song) {
        loadedSongs[song.persistentID] = song
    }
    
    func updateQueueVersion(_ version: Int) {
        // Only clear cache if queue structure changed significantly
        if currentQueueVersion != version && currentQueueVersion != -1 {
            print("🔄 Queue version changed from \(currentQueueVersion) to \(version)")
            // Don't clear the cache - songs are still valid even if queue changes
        }
        currentQueueVersion = version
    }
    
    func clearCache() {
        loadedSongs.removeAll()
        print("🗑️ Song cache cleared")
    }
}

struct QueueView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        NavigationStack {
            Group {
                if audioPlayer.playbackQueue.isEmpty {
                    VStack {
                        Spacer()
                        Text("The queue is empty.")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(0..<audioPlayer.playbackQueue.count, id: \.self) { index in
                                LazyQueueItemView(index: index)
                                    .id("\(audioPlayer.queueVersion)-\(index)")
                            }
                        }
                        .padding(.top, 1)
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
        .padding(16) // Match NowPlayingView padding
    }
}

// Lazy-loading queue item view
private struct LazyQueueItemView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    let index: Int
    @State private var song: Song?
    @GestureState private var isPressed = false
    
    private let songCache = QueueSongCache.shared

    var body: some View {
        ListItemView(
            title: song?.title ?? "Loading...",
            subtitle: song?.artist ?? "",
            isPlaying: index == audioPlayer.currentIndex,
            detail: song?.album ?? "",
            playPauseAction: {
                if song != nil {
                    audioPlayer.playPause()
                }
            },
            isPressed: isPressed
        )
        .opacity(song != nil ? 1.0 : 0.6) // Slightly dim loading items
        .onTapGesture {
            // Allow tap even if song is still loading, as long as we have a valid index
            if index < audioPlayer.playbackQueue.count {
                audioPlayer.playTrack(at: index)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in
                    state = true
                }
        )
        .onAppear {
            loadSongIfNeeded()
        }
    }
    
    private func loadSongIfNeeded() {
        guard let trackID = audioPlayer.playbackQueue.getTrackID(at: index) else { return }
        
        // Update queue version tracking
        songCache.updateQueueVersion(audioPlayer.queueVersion)
        
        // Check cache first
        if let cachedSong = songCache.getSong(trackID: trackID) {
            self.song = cachedSong
            return
        }
        
        // Don't reload if we already have the correct song
        if let currentSong = self.song, currentSong.persistentID == trackID {
            // Cache the song we already have
            songCache.setSong(currentSong)
            return
        }
        
        // Load from library if not cached
        Task {
            if let loadedSong = LibraryService.shared.getSong(by: trackID) {
                await MainActor.run {
                    self.song = loadedSong
                    // Cache the loaded song
                    songCache.setSong(loadedSong)
                }
            }
        }
    }
}

