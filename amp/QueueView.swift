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
    @StateObject private var settings = SettingsService.shared
    @State private var lastCurrentIndex: Int = -1
    @State private var isScrollable = false
    @State private var isAtBottom = false
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom header with controlled spacing
                ZStack(alignment: .leading) {
                    Text("Queue")
                        .font(Theme.titleFont)
                        .foregroundColor(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !audioPlayer.playbackQueue.isEmpty {
                        HStack(spacing: 12) {
                            Button("Loop") {
                                audioPlayer.toggleLoop()
                            }
                            .foregroundColor(audioPlayer.isLooped ? .white : Theme.primaryText)
                            .font(Theme.bodyFont)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                ZStack {
                                    // Layer 1: The hard shadow (offset background) - only show in light mode
                                    if !settings.darkMode {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.buttonShadow)
                                            .offset(x: -6, y: 6)
                                    }

                                    // Layer 2: The main button background
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(audioPlayer.isLooped ? Theme.accentPink : Theme.background)
                                }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.primaryText, lineWidth: 2)
                            )

                            Button("Shuffle") {
                                audioPlayer.toggleShuffle()
                            }
                            .foregroundColor(audioPlayer.isShuffled ? .white : Theme.primaryText)
                            .font(Theme.bodyFont)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                ZStack {
                                    // Layer 1: The hard shadow (offset background) - only show in light mode
                                    if !settings.darkMode {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.buttonShadow)
                                            .offset(x: -6, y: 6)
                                    }

                                    // Layer 2: The main button background
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(audioPlayer.isShuffled ? Theme.accentPink : Theme.background)
                                }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.primaryText, lineWidth: 2)
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(height: 28)
                .padding(.vertical, 20)
                .padding(.horizontal, 16)
                .background(Theme.background)

                // Separator line below header
                Rectangle()
                    .fill(Theme.primaryText)
                    .frame(height: 2)

                // Content area
                GeometryReader { geometry in
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
                                    VStack(spacing: 0) {
                                        LazyVStack(spacing: 0) {
                                            ForEach(0..<audioPlayer.playbackQueue.count, id: \.self) { index in
                                                LazyQueueItemView(index: index)
                                                    .id("item-\(index)-\(audioPlayer.queueVersion)")
                                            }
                                        }
                                        .id("queue-\(audioPlayer.queueVersion)")

                                        // Invisible anchor at the bottom to track scroll position
                                        Color.clear
                                            .frame(height: 1)
                                            .background(
                                                GeometryReader { bottomGeometry in
                                                    Color.clear.preference(
                                                        key: ScrollOffsetPreferenceKey.self,
                                                        value: bottomGeometry.frame(in: .named("queue-scroll")).minY
                                                    )
                                                }
                                            )
                                    }
                                    .background(
                                        GeometryReader { contentGeometry in
                                            Color.clear.preference(
                                                key: ContentHeightPreferenceKey.self,
                                                value: contentGeometry.size.height
                                            )
                                        }
                                    )
                                }
                                .coordinateSpace(name: "queue-scroll")
                                .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
                                    contentHeight = height
                                    viewportHeight = geometry.size.height
                                    isScrollable = height > geometry.size.height
                                }
                                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { bottomOffset in
                                    // bottomOffset is the Y position of the bottom anchor in the scroll view
                                    // When at top: bottomOffset ≈ contentHeight
                                    // When at bottom: bottomOffset ≈ viewportHeight
                                    let threshold: CGFloat = 20

                                    if isScrollable {
                                        // We're at the bottom when the bottom anchor is visible near the bottom of viewport
                                        isAtBottom = bottomOffset <= (viewportHeight + threshold)
                                    } else {
                                        // Content fits entirely in viewport
                                        isAtBottom = true
                                    }
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

                                    // Scroll to the currently playing track on appear (no animation to prevent jank)
                                    if currentIndex >= 0 {
                                        proxy.scrollTo("item-\(currentIndex)-\(audioPlayer.queueVersion)", anchor: .top)
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
                }

                Spacer()

                // Bottom bars section - only show when content is scrollable AND not at bottom
                if isScrollable && !isAtBottom {
                    VStack(spacing: 0) {
                        // Light blue gradient bar (16px)
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [.white.opacity(0), Theme.accentSkyBlue]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 16)

                        // 2px separator bar with 10px bottom padding
                        Rectangle()
                            .fill(Theme.primaryText)
                            .frame(height: 2)
                            .padding(.bottom, 10)
                    }
                    .transition(.opacity)
                }
            }
            .navigationBarHidden(true)
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
        VStack(spacing: 0) {
            ListItemView(
                title: song?.title ?? "Loading...",
                subtitle: song?.artist ?? "",
                isPlaying: index == audioPlayer.currentIndex,
                detail: nil,
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
        }
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

