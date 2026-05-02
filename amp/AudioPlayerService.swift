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

    // Tracks the user's most recent navigation intent across the
    // synchronous queueManager → delegate → playbackEngine call chain.
    // Set in the public wrapper (startPlayback / playTrack / nextTrack /
    // previousTrack), read by currentTrackDidChange (force-play vs
    // preserve-paused, suppress notification) and by playbackDidFinish
    // (recovery direction). Reset via defer when the wrapper returns.
    private enum UserAction {
        case none           // auto-advance, eager load, queue restore
        case selectTrack    // explicit play (queue tap, startPlayback)
        case nextTrack      // user pressed next
        case previousTrack  // user pressed prev
    }
    private var pendingUserAction: UserAction = .none

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

        pendingUserAction = .selectTrack
        defer { pendingUserAction = .none }

        queueManager.startPlayback(from: songs, startingWith: startSong)
        navigation.navigateToNowPlaying()
        // queueManager.startPlayback fires currentTrackDidChange synchronously;
        // the delegate handles playback (sees .selectTrack → play with isManualSelection=true).
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

        // Sanity-check: confirm the starting track ID is in the library.
        // queueManager.startPlayback would fail less gracefully without this.
        guard LibraryService.shared.getSong(by: trackIDs[index]) != nil else {
            print("❌ [AudioPlayerService] Could not hydrate starting track \(trackIDs[index])")
            return
        }

        print("🎵 [AudioPlayerService] startPlayback (IDs) \(trackIDs.count) tracks, starting at index \(index)")

        pendingUserAction = .selectTrack
        defer { pendingUserAction = .none }

        queueManager.startPlayback(fromTrackIDs: trackIDs, startingAt: index)
        if navigateToNowPlaying {
            navigation.navigateToNowPlaying()
        }
        // Delegate handles playback (sees .selectTrack → play with isManualSelection=true).
    }
    
    func playTrack(at index: Int) {
        pendingUserAction = .selectTrack
        defer { pendingUserAction = .none }

        // queueManager.playTrack fires currentTrackDidChange synchronously;
        // the delegate plays the track (sees .selectTrack → force play).
        // No navigateToNowPlaying() here — Queue taps keep the user on
        // Queue so they can play/pause and jump around without losing
        // context. "Start playback from Library / Search" still routes
        // to Now Playing via the startPlayback(...) variants.
        _ = queueManager.playTrack(at: index)
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
        pendingUserAction = .nextTrack
        defer { pendingUserAction = .none }
        // Delegate handles playback. Sees .nextTrack → preserves current
        // play/pause state. Failure recovery in playbackDidFinish reads
        // .nextTrack → forward direction.
        _ = queueManager.nextTrack()
    }

    func previousTrack() {
        // If more than 4 seconds into the track, restart current track.
        if playbackTime > 4.0 {
            playbackEngine.seek(to: 0)
            return
        }

        pendingUserAction = .previousTrack
        defer { pendingUserAction = .none }
        // Delegate handles playback. Sees .previousTrack → preserves current
        // play/pause state. Failure recovery reads .previousTrack → backward
        // direction (skip a broken track in the user's intended direction).
        _ = queueManager.previousTrack()
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
            print("❌ [AudioPlayerService] Track failed to load — \(currentTrack?.title ?? "Unknown")")
            guard queueManager.playbackQueue.trackIDs.count > 1 else {
                print("⚠️ [AudioPlayerService] No more tracks in queue — playback stopped")
                return
            }

            isAutoAdvancing = true
            defer { isAutoAdvancing = false }

            // Direction-aware recovery: skip the broken track in the
            // direction the user was navigating. previousTrack failures
            // recover backward; everything else (next, tap, auto-advance)
            // recovers forward. If backward recovery hits the start of
            // the queue, we don't fall back to forward — that would
            // unexpectedly jump the user past their intended destination.
            // The consecutiveLoadFailures cap (5, in PlaybackEngineService)
            // bounds any cascade if multiple adjacent tracks fail.
            if case .previousTrack = pendingUserAction {
                print("🔄 [AudioPlayerService] Recovering backward (user was going prev)")
                _ = queueManager.previousTrack()
            } else {
                print("🔄 [AudioPlayerService] Recovering forward")
                _ = queueManager.nextTrack()
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
        guard let track = track else { return }

        // Single decision point for what to do when the current track
        // changes. Driven by pendingUserAction (set by the public wrappers)
        // and isAutoAdvancing (set during recovery / track-end advance).
        let isManual: Bool
        let shouldPlay: Bool

        switch pendingUserAction {
        case .selectTrack:
            // Explicit play (queue tap, startPlayback) — force play, suppress notification.
            isManual = true
            shouldPlay = true
        case .nextTrack, .previousTrack:
            // User-driven nav — preserve current play/pause state.
            // isAutoAdvancing covers the in-cascade recovery case
            // (a recovered track keeps playing).
            isManual = true
            shouldPlay = isAutoAdvancing || isPlaying
        case .none:
            // Auto-advance from track-end, queue restore, eager-load reconcile.
            isManual = false
            shouldPlay = isAutoAdvancing || isPlaying
        }

        if shouldPlay {
            playbackEngine.play(song: track, isManualSelection: isManual)
        } else {
            playbackEngine.loadWithoutPlaying(song: track)
            // Restore persisted playback position if available (post-launch).
            if let position = queueManager.restoredPlaybackPosition, position > 0 {
                playbackEngine.seek(to: position)
                print("[AudioPlayerService] ✅ Restored playback position: \(position)s")
                queueManager.restoredPlaybackPosition = nil
            }
        }
    }
}