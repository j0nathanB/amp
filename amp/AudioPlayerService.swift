import Foundation
import SwiftUI
import Combine

class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    // Services
    private let playbackEngine = PlaybackEngineService()
    let queueManager = QueueManagerService()  // Made internal for app lifecycle access
    private let navigation = NavigationService()

    // Track whether we're auto-advancing after track completion
    private var isAutoAdvancing = false

    // Playback transition state to prevent delegate double-play
    private enum PlaybackTransition {
        case none
        case transitioning(to: Song)
    }
    private var transitionState: PlaybackTransition = .none

    // Combine cancellables
    private var cancellables = Set<AnyCancellable>()

    // Public interface - delegate to services
    @Published var isPlaying = false
    @Published var currentTrack: Song?
    @Published var enrichedCurrentTrack: Song? // Current track with enriched metadata from audio file
    @Published var songDuration: TimeInterval = 0.0
    @Published var playbackTime: TimeInterval = 0.0
    @Published var currentOutputName: String = ""
    @Published var isShuffled = false
    @Published var isLooped = false
    @Published var isLoopingSong = false
    @Published var selectedTab: Tab = .queue
    @Published var currentIndex: Int = -1
    @Published var systemVolume: Float = 1.0
    
    // Queue properties
    var playbackQueue: PlaybackQueue {
        return queueManager.playbackQueue
    }
    
    var queueVersion: Int {
        return queueManager.queueVersion
    }
    
    private init() {
        // Set up delegates
        playbackEngine.delegate = self
        queueManager.delegate = self

        // Bind published properties
        setupBindings()

        // Set up notifications for remote commands
        setupNotifications()

        // Load song loop state
        isLoopingSong = UserDefaults.standard.bool(forKey: "songLoopEnabled")
    }
    
    private func setupBindings() {
        // Bind playback engine properties
        playbackEngine.$isPlaying
            .assign(to: &$isPlaying)
        
        playbackEngine.$songDuration
            .assign(to: &$songDuration)
        
        playbackEngine.$playbackTime
            .assign(to: &$playbackTime)
        
        playbackEngine.$currentOutputName
            .assign(to: &$currentOutputName)
        
        playbackEngine.$systemVolume
            .assign(to: &$systemVolume)
        
        // Bind queue manager properties
        queueManager.$currentTrack
            .assign(to: &$currentTrack)

        // Enrich current track with metadata from audio file
        $currentTrack
            .sink { [weak self] track in
                guard let self = self else { return }

                // Set enrichedCurrentTrack to the current track immediately (no flash)
                self.enrichedCurrentTrack = track

                // If track exists and has no release date, enrich it asynchronously
                if let track = track, track.releaseDate == nil {
                    Task {
                        let enriched = await LibraryService.shared.enrichSongWithFileMetadata(track)
                        await MainActor.run {
                            // Only update if this is still the current track
                            if self.currentTrack?.id == enriched.id {
                                self.enrichedCurrentTrack = enriched
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)

        queueManager.$isShuffled
            .assign(to: &$isShuffled)
        
        queueManager.$isLooped
            .assign(to: &$isLooped)
        
        // Bind navigation properties
        navigation.$selectedTab
            .assign(to: &$selectedTab)
        
        // Bind currentIndex from playbackQueue changes
        queueManager.$playbackQueue
            .map { $0.currentIndex ?? -1 }
            .assign(to: &$currentIndex)
    }
    
    // MARK: - Public API (same as before)
    
    func startPlayback(from songs: [Song], startingWith startSong: Song) {
        print("🎵 [AudioPlayerService] startPlayback called with \(songs.count) songs, starting with: \(startSong.title)")

        // Set transition state to prevent delegate from also starting playback
        transitionState = .transitioning(to: startSong)

        queueManager.startPlayback(from: songs, startingWith: startSong)
        navigation.navigateToNowPlaying()

        // Get the track directly from queueManager to avoid Combine binding race condition
        if let track = queueManager.currentTrack {
            print("✅ [AudioPlayerService] Current track set, calling playbackEngine.play() for: \(track.title)")
            playbackEngine.play(song: track, isManualSelection: true)
        } else {
            print("❌ [AudioPlayerService] ERROR: Current track is nil after startPlayback!")
        }

        // Clear transition state immediately after manual playback
        transitionState = .none
    }
    
    func playTrack(at index: Int) {
        if let track = queueManager.playTrack(at: index) {
            // Set transition state to prevent delegate from also starting playback
            transitionState = .transitioning(to: track)

            playbackEngine.play(song: track, isManualSelection: true)
            navigation.navigateToNowPlaying()

            // Clear transition state immediately after manual playback
            transitionState = .none
        }
    }
    
    func playPause() {
        playbackEngine.playPause()
        // Sync position for persistence before updating session state
        queueManager.currentPlaybackPosition = playbackTime
        // Update session state based on play/pause
        if playbackEngine.isPlaying {
            queueManager.resumeSession()
        } else {
            queueManager.pauseSession()
        }
    }
    
    func nextTrack() {
        if let track = queueManager.nextTrack() {
            if isPlaying {
                playbackEngine.play(song: track, isManualSelection: true)
            } else {
                // If paused, just load the track without playing
                playbackEngine.loadWithoutPlaying(song: track)
            }
        }
    }
    
    func previousTrack() {
        if let track = queueManager.previousTrack() {
            if isPlaying {
                playbackEngine.play(song: track, isManualSelection: true)
            } else {
                // If paused, just load the track without playing
                playbackEngine.loadWithoutPlaying(song: track)
            }
        }
    }
    
    func seek(to time: TimeInterval) {
        playbackEngine.seek(to: time)
    }
    
    func shuffleCurrentQueue() {
        queueManager.shuffleCurrentQueue()
    }
    
    func toggleShuffle() {
        queueManager.toggleShuffle()
    }
    
    func toggleLoop() {
        queueManager.toggleLoop()
    }

    func toggleSongLoop() {
        isLoopingSong.toggle()
        UserDefaults.standard.set(isLoopingSong, forKey: "songLoopEnabled")
        print("[AudioPlayerService] Song loop toggled to: \(isLoopingSong)")
    }
    
    // MARK: - Navigation
    
    func navigateToNowPlaying() {
        navigation.navigateToNowPlaying()
    }
    
    func navigateToQueue() {
        navigation.navigateToQueue()
    }
    
    // Debug method to refresh Now Playing info
    func refreshNowPlayingInfo() {
        playbackEngine.refreshNowPlayingInfo()
    }
    
    // Internal method for service coordination
    internal func notifyMemoryCleanup() {
        queueManager.notifyMemoryCleanup()
    }
    
    // MARK: - Private Methods
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlayPreviousTrack),
            name: Notification.Name("PlayPreviousTrack"),
            object: nil
        )
    }
    
    @objc private func handlePlayPreviousTrack() {
        previousTrack()
    }
}

// MARK: - Debug/Testing Methods

#if DEBUG
extension AudioPlayerService {
    func debugPersistenceInfo() -> String {
        return QueuePersistenceService.shared.debugInfo()
    }
    
    func debugClearAllStorage() async {
        await QueuePersistenceService.shared.clearAllStorage()
        print("[AudioPlayerService] Cleared all queue storage")
    }
    
    func debugForceLoadQueue() async {
        await queueManager.loadQueue()
        print("[AudioPlayerService] Force reloaded queue from storage")
    }
    
    func debugForceSaveQueue() {
        queueManager.saveQueue()
        print("[AudioPlayerService] Force saved current queue to storage")
    }
}
#endif

// MARK: - PlaybackEngineDelegate

extension AudioPlayerService: PlaybackEngineDelegate {
    func playbackDidFinish(successfully: Bool) {
        if successfully {
            print("[AudioPlayerService] ✅ Track finished successfully")
            // Check if song loop is enabled - if so, replay the current track
            if isLoopingSong, let track = currentTrack {
                print("[AudioPlayerService] Song loop enabled - replaying: \(track.title)")
                playbackEngine.play(song: track, isManualSelection: false)
            } else {
                // When a track finishes, automatically advance to the next track
                // Set flag to indicate we're auto-advancing (should continue playing)
                isAutoAdvancing = true
                _ = queueManager.nextTrack()
                isAutoAdvancing = false
            }
        } else {
            // ⚠️ Track failed to finish - this indicates an error
            print("❌ [AudioPlayerService] Track failed to finish properly!")
            print("❌ [AudioPlayerService] This could be due to:")
            print("   - Audio session interruption (phone call, alarm, notification)")
            print("   - Audio hardware error")
            print("   - File read error")
            print("   - Memory pressure")
            print("❌ [AudioPlayerService] Current track: \(currentTrack?.title ?? "Unknown")")

            // Attempt recovery by trying to continue to next track
            // This prevents the player from getting stuck
            if queueManager.playbackQueue.trackIDs.count > 1 {
                print("🔄 [AudioPlayerService] Attempting recovery - advancing to next track")
                isAutoAdvancing = true
                _ = queueManager.nextTrack()
                isAutoAdvancing = false
            } else {
                print("⚠️ [AudioPlayerService] No more tracks in queue - playback stopped")
            }
        }
    }

    func playbackTimeDidUpdate(_ time: TimeInterval) {
        // Keep queue manager's position in sync for persistence
        queueManager.currentPlaybackPosition = time
    }
}

// MARK: - QueueManagerDelegate

extension AudioPlayerService: QueueManagerDelegate {
    func queueDidChange() {
        // Trigger UI updates - objectWillChange is automatically called
        // due to @Published properties in queueManager
    }

    func currentTrackDidChange(_ track: Song?) {
        // Skip delegate-triggered playback if we're in a manual transition
        // Check if the incoming track matches the target of our transition
        if case .transitioning(let targetSong) = transitionState, track?.id == targetSong.id {
            print("[AudioPlayerService] Skipping delegate playback - manual transition in progress for: \(targetSong.title)")
            return
        }

        // This is called when the current track changes (manual or automatic)
        if let track = track {
            // If we're auto-advancing (track finished), continue playing
            // Otherwise, respect the current play/pause state
            if isAutoAdvancing {
                playbackEngine.play(song: track, isManualSelection: false)
            } else if isPlaying {
                playbackEngine.play(song: track, isManualSelection: false)
            } else {
                playbackEngine.loadWithoutPlaying(song: track)
                // Restore persisted playback position if available (e.g., after app restart)
                if let position = queueManager.restoredPlaybackPosition, position > 0 {
                    playbackEngine.seek(to: position)
                    print("[AudioPlayerService] ✅ Restored playback position: \(position)s")
                    queueManager.restoredPlaybackPosition = nil
                }
            }
        }
    }
}