import Foundation
import SwiftUI
import Combine
import MediaPlayer

class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    // Services
    private let playbackEngine = PlaybackEngineService()
    let queueManager = QueueManagerService()  // Made internal for app lifecycle access
    private let navigation = NavigationService.shared

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
    @Published var isBluetoothRouteActive: Bool = false
    @Published var isWiredRouteActive: Bool = false
    @Published var isShuffled = false
    @Published var isLooped = false
    @Published var isLoopingSong = false
    @Published var currentIndex: Int = -1
    @Published var systemVolume: Float = 1.0
    @Published var queueInitialLoadCompleted: Bool = false
    
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

        // Eager current-track restoration.
        //
        // Reads a ~500-byte sidecar file synchronously, opens the AVAudioFile
        // with the cached asset URL (bypassing MPMediaQuery), and applies the
        // track to QueueManager — all before the full queue restore fires via
        // QueueManager.loadQueueOnce. Net effect: play button works within
        // ~30-50ms of cold launch instead of waiting for the full queue
        // pipeline (disk decode + song batch-fetch + mutate + delegate +
        // AVAudioFile open).
        //
        // Order matters: must run AFTER queueManager.init() (so the instance
        // exists and Task { await loadQueueOnce() } has been scheduled) but
        // BEFORE that task actually executes on the runloop. Sync file read +
        // sync PlaybackEngine.loadWithURL satisfies this — both complete
        // before the awaiting queue-restore task gets a turn.
        //
        // Failure modes (all one-line-logged so device testing can grep for
        // the hit-vs-miss ratio):
        //   - no snapshot file (fresh install / first launch) → normal flow
        //   - snapshot decode fails → normal flow (file self-heals on next save)
        //   - AVAudioFile open fails (stale URL from library edit, or iCloud
        //     Music Library item that isn't locally downloaded) → don't apply
        //     snapshot to QueueManager, let normal restore handle it
        //
        // Watch the hit rate on device. If <~70% on typical libraries, the
        // assetURL is probably stale too often (cloud-heavy libraries, iTunes
        // Match) and the eager path's complexity cost isn't paid back. Mitigation
        // would be storing a per-track mtime/checksum alongside the URL — but
        // don't add that unless the ratio data says so.
        if let snapshot = CurrentTrackSnapshot.loadFromDisk() {
            let audioReady = playbackEngine.loadWithURL(
                song: snapshot.song,
                url: snapshot.assetURL,
                seekTo: snapshot.playbackPosition
            )
            if audioReady {
                queueManager.applyEagerTrackSnapshot(snapshot)
                print("[PERF] eager.hit track=\(snapshot.song.title)")
            } else {
                print("[PERF] eager.miss reason=av-file-open-failed track=\(snapshot.song.title)")
            }
        } else {
            print("[PERF] eager.miss reason=no-valid-snapshot")
        }
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

        playbackEngine.$isBluetoothRouteActive
            .assign(to: &$isBluetoothRouteActive)

        playbackEngine.$isWiredRouteActive
            .assign(to: &$isWiredRouteActive)
        
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
        
        // Bind currentIndex from playbackQueue changes
        queueManager.$playbackQueue
            .map { $0.currentIndex ?? -1 }
            .assign(to: &$currentIndex)

        queueManager.$initialLoadCompleted
            .assign(to: &$queueInitialLoadCompleted)
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

    // `navigateToNowPlaying` is an opt-out for detail views (Album /
    // Playlist / Artist) that want to start playback without leaving their
    // context — highlighting + play/pause happen in-place, matching how
    // Queue taps behave. Library / Search still jump to Now Playing via
    // the default (true).
    func startPlayback(fromTrackIDs trackIDs: [MPMediaEntityPersistentID],
                       startingAt index: Int = 0,
                       navigateToNowPlaying: Bool = true) {
        guard !trackIDs.isEmpty, index >= 0, index < trackIDs.count else {
            print("❌ [AudioPlayerService] Invalid IDs startPlayback: count=\(trackIDs.count) index=\(index)")
            return
        }

        // Pre-hydrate the starting track so transitionState can be set before
        // queueManager.startPlayback fires currentTrackDidChange through the delegate.
        guard let startSong = LibraryService.shared.getSong(by: trackIDs[index]) else {
            print("❌ [AudioPlayerService] Could not hydrate starting track \(trackIDs[index])")
            return
        }

        print("🎵 [AudioPlayerService] startPlayback (IDs) \(trackIDs.count) tracks, starting with: \(startSong.title)")

        transitionState = .transitioning(to: startSong)

        queueManager.startPlayback(fromTrackIDs: trackIDs, startingAt: index)
        if navigateToNowPlaying {
            navigation.navigateToNowPlaying()
        }

        if let track = queueManager.currentTrack {
            playbackEngine.play(song: track, isManualSelection: true)
        } else {
            print("❌ [AudioPlayerService] ERROR: Current track is nil after IDs startPlayback!")
        }

        transitionState = .none
    }
    
    func playTrack(at index: Int) {
        if let track = queueManager.playTrack(at: index) {
            // Set transition state to prevent delegate from also starting playback
            transitionState = .transitioning(to: track)

            playbackEngine.play(song: track, isManualSelection: true)
            // No navigateToNowPlaying() here — Queue taps keep the user on
            // Queue so they can play/pause and jump around without losing
            // context. "Start playback from Library / Search" still routes
            // to Now Playing via the startPlayback(...) variants.

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
        // If more than 4 seconds into the track, restart current track
        if playbackTime > 4.0 {
            playbackEngine.seek(to: 0)
            return
        }
        // Otherwise, go to previous track
        if let track = queueManager.previousTrack() {
            if isPlaying {
                playbackEngine.play(song: track, isManualSelection: true)
            } else {
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