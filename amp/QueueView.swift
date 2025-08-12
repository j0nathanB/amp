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

// Singleton to manage queue view state across tab switches
class QueueViewState: ObservableObject {
    static let shared = QueueViewState()
    
    @Published var lastKnownCurrentIndex: Int = -1
    @Published var isActivelyViewing: Bool = false
    
    private init() {}
    
    func updateCurrentIndex(_ index: Int) {
        lastKnownCurrentIndex = index
    }
    
    func setActiveViewing(_ active: Bool) {
        isActivelyViewing = active
    }
}

struct QueueView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @StateObject private var viewState = QueueViewState.shared
    @State private var lastCurrentIndex: Int = -1
    
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
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(0..<audioPlayer.playbackQueue.count, id: \.self) { index in
                                    LazyQueueItemView(index: index)
                                        .id("item-\(index)-\(audioPlayer.queueVersion)")
                                }
                            }
                            .id("queue-\(audioPlayer.queueVersion)")
                            .padding(.top, 1)
                        }
                        .onChange(of: audioPlayer.currentIndex) { oldIndex, newIndex in
                            let wasTracking = viewState.lastKnownCurrentIndex == oldIndex
                            
                            guard newIndex >= 0 else { return }
                            
                            // Only auto-scroll if user is actively viewing AND we were tracking the previous song
                            if viewState.isActivelyViewing && wasTracking {
                                // User is actively viewing and song changed - smooth scroll
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    proxy.scrollTo("item-\(newIndex)-\(audioPlayer.queueVersion)", anchor: .top)
                                }
                            }
                            
                            viewState.updateCurrentIndex(newIndex)
                            lastCurrentIndex = newIndex
                        }
                        .onAppear {
                            viewState.setActiveViewing(true)
                            
                            let currentIndex = audioPlayer.currentIndex
                            
                            // Always scroll to the currently playing track on appear
                            if currentIndex >= 0 {
                                DispatchQueue.main.async {
                                    proxy.scrollTo("item-\(currentIndex)-\(audioPlayer.queueVersion)", anchor: .top)
                                }
                            }
                            
                            viewState.updateCurrentIndex(currentIndex)
                            lastCurrentIndex = currentIndex
                        }
                        .onDisappear {
                            viewState.setActiveViewing(false)
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
            isPressed: isPressed,
            showTopBorder: index == 0 // Only show top border for first item
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

