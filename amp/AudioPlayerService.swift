import Foundation
import SwiftUI

class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    // Services
    private let playbackEngine = PlaybackEngineService()
    let queueManager = QueueManagerService()  // Made internal for app lifecycle access
    private let navigation = NavigationService()

    // Track whether we're auto-advancing after track completion
    private var isAutoAdvancing = false

    // Track whether we're manually starting playback (to prevent delegate double-play)
    private var isManuallyStarting = false

    // Public interface - delegate to services
    @Published var isPlaying = false
    @Published var currentTrack: Song?
    @Published var songDuration: TimeInterval = 0.0
    @Published var playbackTime: TimeInterval = 0.0
    @Published var currentOutputName: String = ""
    @Published var isShuffled = false
    @Published var isLooped = false
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
        // Set flag to prevent delegate from also starting playback
        isManuallyStarting = true

        queueManager.startPlayback(from: songs, startingWith: startSong)
        navigation.navigateToNowPlaying()

        // Get the track directly from queueManager to avoid Combine binding race condition
        if let track = queueManager.currentTrack {
            playbackEngine.play(song: track, isManualSelection: true)
        }

        // Clear flag after a brief delay to allow delegate to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isManuallyStarting = false
        }
    }
    
    func playTrack(at index: Int) {
        // Set flag to prevent delegate from also starting playback
        isManuallyStarting = true

        if let track = queueManager.playTrack(at: index) {
            playbackEngine.play(song: track, isManualSelection: true)
            navigation.navigateToNowPlaying()
        }

        // Clear flag after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isManuallyStarting = false
        }
    }
    
    func playPause() {
        playbackEngine.playPause()
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
            // When a track finishes, automatically advance to the next track
            // Set flag to indicate we're auto-advancing (should continue playing)
            isAutoAdvancing = true
            _ = queueManager.nextTrack()
            isAutoAdvancing = false
        }
    }

    func playbackTimeDidUpdate(_ time: TimeInterval) {
        // Already bound via Combine, but could add additional logic here
    }
}

// MARK: - QueueManagerDelegate

extension AudioPlayerService: QueueManagerDelegate {
    func queueDidChange() {
        // Trigger UI updates - objectWillChange is automatically called
        // due to @Published properties in queueManager
    }

    func currentTrackDidChange(_ track: Song?) {
        // Skip delegate-triggered playback if we're manually starting
        // This prevents double playback calls
        guard !isManuallyStarting else {
            print("[AudioPlayerService] Skipping delegate playback - manual start in progress")
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
            }
        }
    }
}