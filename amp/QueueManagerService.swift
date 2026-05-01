import Foundation
import MediaPlayer
import CryptoKit

protocol QueueManagerDelegate: AnyObject {
    func queueDidChange()
    func currentTrackDidChange(_ track: Song?)
}

class QueueManagerService: ObservableObject {
    weak var delegate: QueueManagerDelegate?
    
    @Published private(set) var playbackQueue = PlaybackQueue()
    @Published private(set) var queueVersion = 0
    // Flips true once the initial persisted-queue restore has finished
    // (whether anything was restored or not). QueueView reads this to
    // distinguish "still loading from disk" from "genuinely empty".
    @Published private(set) var initialLoadCompleted = false
    @Published var currentTrack: Song? {
        didSet {
            // Debug logging to track when currentTrack changes
            if let old = oldValue, let new = currentTrack {
                if old.persistentID != new.persistentID {
                    print("🎵 [QueueManager] currentTrack changed: '\(old.title)' → '\(new.title)'")
                    refreshCurrentTrackSnapshot()
                }
            } else if let new = currentTrack {
                print("🎵 [QueueManager] currentTrack set: '\(new.title)'")
                refreshCurrentTrackSnapshot()
            } else {
                print("🎵 [QueueManager] currentTrack cleared")
                CurrentTrackSnapshot.removeFromDisk()
            }
        }
    }
    @Published var isShuffled = false
    @Published var isLooped = false
    
    // Keep for migration only
    private let queueUserDefaultsKey = "savedPlaybackQueueIDs"
    private let persistenceService = QueuePersistenceService.shared
    
    // Flags to prevent recursive loading
    private var isPerformingOperation = false
    private var hasLoadedInitialQueue = false

    // True iff currentTrack was populated by CurrentTrackSnapshot eager
    // load and the full queue restore hasn't yet reconciled. When set,
    // loadQueue's "currentTrack != nil" protection is relaxed — otherwise
    // eager load would permanently block queue restoration. Cleared by:
    //   - successful queue restore (reconciled in loadQueue)
    //   - any user interaction (startPlayback / playTrack / etc.)
    // If you see loadQueue blocking restoration on an eager track, check
    // that you're only setting this in applyEagerTrackSnapshot and only
    // clearing it in the three places above.
    private var isEagerLoad = false

    // Trailing-edge debouncer for current-track snapshot saves. Rapid
    // track skips (scrubbing through a queue) otherwise fire N × (MPMedia-
    // Query + atomic write), all for a snapshot that only matters on next
    // cold launch. 500ms coalesces a burst into a single write at the
    // user's resting state. Flushed explicitly on enterBackground /
    // endSession so a device-lock-mid-burst still persists fresh state.
    private var snapshotSaveWorkItem: DispatchWorkItem?
    private static let snapshotSaveDebounce: TimeInterval = 0.5

    // Playback position tracking for persistence
    var currentPlaybackPosition: TimeInterval = 0
    var restoredPlaybackPosition: TimeInterval?
    
    // Session state management
    enum SessionState {
        case idle
        case active
        case paused
        case background
        
        var description: String {
            switch self {
            case .idle: return "idle"
            case .active: return "active"
            case .paused: return "paused"
            case .background: return "background"
            }
        }
    }
    
    private var sessionState: SessionState = .idle
    private var sessionStartTime: Date?
    private var lastUserInteraction = Date()
    private var hasActiveSession = false
    private var stateBeforeBackground: SessionState?
    
    init() {
        self.isShuffled = UserDefaults.standard.bool(forKey: "shuffleOnStart")
        self.isLooped = UserDefaults.standard.bool(forKey: "loopEnabled")
        // Load queue asynchronously to avoid blocking main thread - ONLY ONCE
        Task {
            await loadQueueOnce()
        }
    }
    
    // MARK: - Queue Management
    
    func startPlayback(from songs: [Song], startingWith startSong: Song) {
        // User interaction supersedes any eager-load state.
        isEagerLoad = false
        // Mark session as active
        sessionState = .active
        hasActiveSession = true
        sessionStartTime = Date()
        lastUserInteraction = Date()
        print("[QueueManager] 🟢 Session started - blocking queue loads")

        playbackQueue.setTracks(songs, startingWith: startSong)
        if isShuffled {
            playbackQueue.shuffle(keepCurrentFirst: true)
        }
        // Trigger @Published update by reassigning the struct
        playbackQueue = playbackQueue
        queueDidChange(triggeredBy: "startPlayback")
        saveQueue()

        if let track = playbackQueue.getCurrentTrack() {
            self.currentTrack = track
            delegate?.currentTrackDidChange(track)
        }
    }

    func startPlayback(fromTrackIDs trackIDs: [MPMediaEntityPersistentID],
                       startingAt index: Int) {
        isEagerLoad = false
        sessionState = .active
        hasActiveSession = true
        sessionStartTime = Date()
        lastUserInteraction = Date()
        print("[QueueManager] 🟢 Session started (IDs path, \(trackIDs.count) tracks)")

        playbackQueue.setTrackIDs(trackIDs, startingIndex: index)
        if isShuffled {
            playbackQueue.shuffle(keepCurrentFirst: true)
        }
        playbackQueue = playbackQueue
        queueDidChange(triggeredBy: "startPlayback-ids")
        saveQueue()

        if let track = playbackQueue.getCurrentTrack() {
            self.currentTrack = track
            delegate?.currentTrackDidChange(track)
        }
    }
    
    func playTrack(at index: Int) -> Song? {
        isEagerLoad = false
        // Mark session as active
        hasActiveSession = true
        sessionState = .active
        lastUserInteraction = Date()
        
        guard let track = playbackQueue.play(at: index) else { return nil }
        
        // Trigger @Published update by reassigning the struct
        playbackQueue = playbackQueue
        currentTrack = track
        queueDidChange(triggeredBy: "playTrack")
        saveQueue()
        delegate?.currentTrackDidChange(track)
        
        return track
    }
    
    func nextTrack() -> Song? {
        lastUserInteraction = Date()
        
        // Try normal next track first
        if let track = playbackQueue.next() {
            // Trigger @Published update by reassigning the struct
            playbackQueue = playbackQueue
            currentTrack = track
            queueDidChange(triggeredBy: "nextTrack")
            saveQueue()
            delegate?.currentTrackDidChange(track)
            return track
        }
        
        // If at end and loop is enabled, go to first track
        if isLooped && !playbackQueue.isEmpty {
            print("[QueueManager] 🔄 Loop enabled - restarting from beginning")
            if let track = playbackQueue.play(at: 0) {
                playbackQueue = playbackQueue
                currentTrack = track
                queueDidChange(triggeredBy: "nextTrack-loop")
                saveQueue()
                delegate?.currentTrackDidChange(track)
                return track
            }
        }
        
        return nil
    }
    
    func previousTrack() -> Song? {
        lastUserInteraction = Date()
        
        guard let track = playbackQueue.previous() else { return nil }
        
        // Trigger @Published update by reassigning the struct
        playbackQueue = playbackQueue
        currentTrack = track
        queueDidChange(triggeredBy: "previousTrack")
        saveQueue()
        delegate?.currentTrackDidChange(track)
        
        return track
    }
    
    func shuffleCurrentQueue() {
        print("[QueueManager] Starting shuffle operation")
        isPerformingOperation = true
        // Ensure flag is always cleared, even if operation returns early or throws
        defer {
            isPerformingOperation = false
            print("[QueueManager] Shuffle operation complete")
        }

        playbackQueue.shuffle(keepCurrentFirst: true)
        // Trigger @Published update by reassigning the struct
        playbackQueue = playbackQueue
        queueDidChange(triggeredBy: "shuffle")
        saveQueue()
    }
    
    func toggleShuffle() {
        print("[QueueManager] Toggling shuffle to: \(!isShuffled)")
        isPerformingOperation = true
        // Ensure flag is always cleared, even if operation returns early or throws
        defer {
            isPerformingOperation = false
            print("[QueueManager] Toggle shuffle operation complete")
        }

        isShuffled.toggle()
        UserDefaults.standard.set(isShuffled, forKey: "shuffleOnStart")

        if isShuffled {
            playbackQueue.shuffle(keepCurrentFirst: true)
            // Trigger @Published update by reassigning the struct
            playbackQueue = playbackQueue
        } else {
            // Restore original order
            playbackQueue.unshuffle()
            playbackQueue = playbackQueue
        }
        queueDidChange(triggeredBy: "toggleShuffle")
        saveQueue()
    }
    
    func toggleLoop() {
        print("[QueueManager] Toggling loop to: \(!isLooped)")
        isLooped.toggle()
        UserDefaults.standard.set(isLooped, forKey: "loopEnabled")
        print("[QueueManager] Loop state saved: \(isLooped)")
        // Note: Loop doesn't modify current queue, only affects playback behavior
    }
    
    // MARK: - Queue Access
    
    func getCurrentTrack() -> Song? {
        return playbackQueue.getCurrentTrack()
    }
    
    func getTrackID(at index: Int) -> MPMediaEntityPersistentID? {
        return playbackQueue.getTrackID(at: index)
    }
    
    var queueCount: Int {
        return playbackQueue.count
    }
    
    var isEmpty: Bool {
        return playbackQueue.isEmpty
    }
    
    var currentIndex: Int {
        return playbackQueue.currentIndex ?? -1
    }
    
    // MARK: - Session Management
    
    func pauseSession() {
        sessionState = .paused
        hasActiveSession = true  // CRITICAL: Keep session active during pause to prevent queue reload
        print("[QueueManager] Session paused - keeping active session flag set")
        // Save but don't load
        saveQueue()
    }
    
    func resumeSession() {
        sessionState = .active
        print("[QueueManager] Session resumed")
        // Don't reload queue
    }
    
    func endSession() {
        sessionState = .idle
        hasActiveSession = false
        sessionStartTime = nil
        print("[QueueManager] Session ended")
        saveQueue()
        // Flush any pending debounced snapshot save — the app may be
        // quitting and we don't want to lose resting-state position.
        flushPendingSnapshotSave()
    }

    func enterBackground() {
        stateBeforeBackground = sessionState
        sessionState = .background
        print("[QueueManager] Entered background - saved previous state: \(stateBeforeBackground?.description ?? "nil")")
        saveQueue()
        // Same rationale: iOS may terminate a backgrounded app at any
        // time, so commit the snapshot immediately rather than waiting
        // for the debounce window.
        flushPendingSnapshotSave()
    }
    
    func enterForeground() {
        if sessionState == .background {
            // Restore the previous state if we have one, otherwise default logic
            if let previousState = stateBeforeBackground {
                sessionState = previousState
                print("[QueueManager] Entered foreground - restored previous state: \(sessionState)")
            } else {
                sessionState = hasActiveSession ? .active : .idle
                print("[QueueManager] Entered foreground - default state: \(sessionState)")
            }
            stateBeforeBackground = nil // Clear the saved state
        }
        // Don't reload queue!
    }
    
    // MARK: - Memory Management Coordination
    
    func notifyMemoryCleanup() {
        // Called when PlaybackEngine cleans up memory during pause
        // This ensures we maintain session state during memory optimization
        if sessionState == .paused {
            print("[QueueManager] Memory cleanup during pause - maintaining session state")
            lastUserInteraction = Date() // Reset timer to prevent queue reload
            // hasActiveSession remains true to block any queue loads
        }
    }
    
    // MARK: - Private Methods
    
    private func queueDidChange(triggeredBy: String = "unknown") {
        print("[QueueManager] Queue changed by: \(triggeredBy)")
        queueVersion += 1
        delegate?.queueDidChange()
        // DO NOT reload the queue here!
    }
    
    internal func saveQueue() {
        // Don't trigger any loads after saving
        print("[QueueManager] Saving queue - currentIndex: \(playbackQueue.currentIndex ?? -1), track: \(currentTrack?.title ?? "none")")

        // CRITICAL FIX: Capture state synchronously on main thread, not in async Task
        // This prevents race conditions where queue state changes between capture and persistence
        let persisted = PersistedQueue(
            savedAt: Date(),
            trackIDs: playbackQueue.getAllTrackIDs(),
            currentIndex: playbackQueue.currentIndex,
            isShuffled: isShuffled,
            isLooped: isLooped,
            originalOrder: playbackQueue.originalOrder,
            checksum: generateChecksum(),
            playbackPosition: currentPlaybackPosition
        )

        // Now persist asynchronously with the already-captured state
        Task {
            await persistenceService.saveQueue(persisted)
            print("[QueueManager] Queue saved successfully - index: \(persisted.currentIndex ?? -1)")
        }

        // Refresh the current-track snapshot whenever the main queue saves.
        // Picks up position updates (saveQueue is called on pause, background,
        // track change, seek, etc.) without adding a separate debouncer.
        refreshCurrentTrackSnapshot()
    }

    // Populates currentTrack from a cold-launch CurrentTrackSnapshot so the
    // Now Playing UI shows something immediately. The full queue restore
    // runs separately (see loadQueueOnce) and is reconciled in loadQueue.
    //
    // Does NOT fire the delegate — AudioPlayerService calls PlaybackEngine
    // directly at eager-load time since the URL is already known from the
    // snapshot; routing through currentTrackDidChange would re-query
    // MediaPlayer and defeat the point.
    //
    // Bails on active session — if the user has already started something,
    // eager load is moot.
    func applyEagerTrackSnapshot(_ snapshot: CurrentTrackSnapshot) {
        guard !hasActiveSession else {
            print("⚡ [QueueManager] Eager snapshot skipped — session already active")
            return
        }
        guard currentTrack == nil else {
            print("⚡ [QueueManager] Eager snapshot skipped — currentTrack already set")
            return
        }
        isEagerLoad = true
        currentTrack = snapshot.song
        // Do NOT seed restoredPlaybackPosition here. The eager path already
        // applied the seek directly to AVAudioPlayer via loadWithURL(seekTo:),
        // and the success-reconcile path in loadQueueOnce doesn't fire the
        // delegate, so a value set here is never consumed for its intended
        // track. It would just sit waiting and get applied to whatever next
        // track the user navigates to (Next/Prev) before pressing Play —
        // which is exactly the "next track starts at 1:23" bug.
        // Seed currentPlaybackPosition to match the snapshot. Without this,
        // the debounced snapshot save that fires 500ms after applyEager…
        // (via currentTrack.didSet → refreshCurrentTrackSnapshot) reads
        // currentPlaybackPosition=0 (default) and writes position 0,
        // overwriting the snapshot we just loaded. User opening the app
        // without interacting would lose their position. playbackTimeDid-
        // Update will take over once playback actually starts.
        currentPlaybackPosition = snapshot.playbackPosition
        print("⚡ [QueueManager] Eager snapshot applied — \(snapshot.song.title) at \(snapshot.playbackPosition)s")
    }

    // Schedules a debounced snapshot write for the current track. Called
    // from currentTrack.didSet (track change) and saveQueue (position-
    // relevant events). Removal (track cleared) is immediate — we don't
    // want a killed-within-debounce app to resurrect a dismissed track.
    private func refreshCurrentTrackSnapshot() {
        guard currentTrack != nil else {
            // Immediate removal — a pending debounced save would otherwise
            // race with the removal and re-create the file post-clear.
            snapshotSaveWorkItem?.cancel()
            snapshotSaveWorkItem = nil
            CurrentTrackSnapshot.removeFromDisk()
            return
        }

        snapshotSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSnapshotSave()
        }
        snapshotSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.snapshotSaveDebounce,
            execute: workItem
        )
    }

    // Forces any pending debounced snapshot save to run immediately.
    // Invoked on lifecycle transitions (enterBackground, endSession) where
    // the app might be terminated before the debounce fires.
    private func flushPendingSnapshotSave() {
        guard let item = snapshotSaveWorkItem, !item.isCancelled else { return }
        item.cancel()
        snapshotSaveWorkItem = nil
        performSnapshotSave()
    }

    // The actual MPMediaQuery + atomic write, off-main via Task.detached.
    // Captures state at call time so the debounced snapshot reflects the
    // most recent track, not an earlier one from a skip burst.
    private func performSnapshotSave() {
        guard let track = currentTrack else { return }
        let position = currentPlaybackPosition
        let index = playbackQueue.currentIndex

        Task.detached(priority: .background) {
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: track.persistentID),
                forProperty: MPMediaItemPropertyPersistentID
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            guard let url = query.items?.first?.assetURL else {
                print("⚡ Snapshot refresh: no assetURL for \(track.title)")
                return
            }

            let snapshot = CurrentTrackSnapshot(
                version: CurrentTrackSnapshot.currentVersion,
                savedAt: Date(),
                song: track,
                assetURL: url,
                playbackPosition: position,
                currentIndex: index
            )
            CurrentTrackSnapshot.saveToDisk(snapshot)
        }
    }
    
    private func generateChecksum() -> String {
        let trackIDs = playbackQueue.getAllTrackIDs()
        let idString = trackIDs.map { String($0) }.joined(separator: ",")
        let data = Data(idString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func loadQueueOnce() async {
        // Only load once at startup
        guard !hasLoadedInitialQueue else {
            print("[QueueManager] Queue already loaded once, skipping")
            return
        }
        hasLoadedInitialQueue = true
        await loadQueue()
        await MainActor.run { self.initialLoadCompleted = true }
    }
    
    internal func loadQueue() async {
        // Log entry to loadQueue with current state
        print("⚠️ [QueueManager] loadQueue() ENTERED - currentTrack: \(currentTrack?.title ?? "nil"), queueSize: \(playbackQueue.count), hasActiveSession: \(hasActiveSession), isEagerLoad: \(isEagerLoad)")

        // CRITICAL SAFETY CHECK: Never load queue if there's ANY sign of active playback

        // Check 1: Never load if we have a current track — UNLESS that track
        // came from the eager-load snapshot. Eager state is *expected* to
        // coexist with a pending queue restore; otherwise the eager
        // optimization permanently blocks restoration.
        if currentTrack != nil && !isEagerLoad {
            print("[QueueManager] 🛡️ PROTECTION 1: Refusing load - current track exists (user-driven): \(currentTrack?.title ?? "unknown")")
            return
        }

        // Check 2: Never load if queue is not empty
        if !playbackQueue.isEmpty {
            print("[QueueManager] 🛡️ PROTECTION 2: Refusing load - queue not empty (size: \(playbackQueue.count))")
            return
        }

        // Check 3: Never load during active session
        if hasActiveSession {
            print("[QueueManager] 🛡️ PROTECTION 3: Refusing load - active session in progress")
            return
        }
        
        // Critical debug: Log call stack to find trigger
        print("🔴 [QueueManager] loadQueue called")
        print("🔴 [QueueManager] Session state: \(sessionState)")
        print("🔴 [QueueManager] Has active session: \(hasActiveSession)")
        print("🔴 [QueueManager] Current track: \(currentTrack?.title ?? "none")")
        print("🔴 [QueueManager] Is performing operation: \(isPerformingOperation)")
        
        // Log call stack to identify the trigger
        Thread.callStackSymbols.prefix(15).enumerated().forEach { index, symbol in
            if symbol.contains("amp") {
                print("🔴 [QueueManager] Stack[\(index)]: \(symbol)")
            }
        }
        
        // CRITICAL: Never load queue during active session
        guard !hasActiveSession else {
            print("[QueueManager] ⛔ BLOCKED: Attempted to load queue during active session")
            return
        }
        
        // REMOVED: 30-second user interaction timeout that was causing queue resets
        // The existing session state and current track protections below are sufficient
        
        // Don't load if we have a current track (active or paused playback)
        // — again, eager-load state is exempt.
        guard currentTrack == nil || isEagerLoad else {
            print("[QueueManager] ⛔ BLOCKED: Not loading - track is active (user-driven): \(currentTrack?.title ?? "unknown")")
            return
        }
        
        // Extra safety: Don't load if session is paused (user might be taking a break)
        guard sessionState != .paused else {
            print("[QueueManager] ⛔ BLOCKED: Not loading during paused session")
            return
        }
        
        // Prevent loading during operations
        guard !isPerformingOperation else {
            print("[QueueManager] ⛔ BLOCKED: Operation in progress")
            return
        }
        
        // If we already have a queue, don't reload unless explicitly requested
        if !playbackQueue.isEmpty && hasLoadedInitialQueue {
            print("[QueueManager] ⛔ BLOCKED: Queue already populated")
            return
        }
        
        print("[QueueManager] ✅ Loading queue for app restoration")

        // Try loading from file-based storage
        if let persisted = await persistenceService.loadQueue() {
            // OPTIMIZED: Batch fetch all songs in one query instead of N queries
            let songDictionary = LibraryService.shared.getSongs(by: persisted.trackIDs)

            // Filter to only IDs that exist in the library, maintaining order
            let validTrackIDs: [MPMediaEntityPersistentID] = persisted.trackIDs.filter { id in
                songDictionary[id] != nil
            }

            guard !validTrackIDs.isEmpty else {
                print("[QueueManager] No valid tracks found in persisted queue")
                return
            }

            // Convert IDs to songs using O(1) dictionary lookup
            let songs: [Song] = validTrackIDs.compactMap { id in
                songDictionary[id]
            }

            let validOriginalOrder = persisted.originalOrder.filter { validTrackIDs.contains($0) }
            let shuffled = persisted.isShuffled
            let currentIndex = persisted.currentIndex
            
            await MainActor.run {
                // CRITICAL FAIL-SAFE: Check state again before mutating queue.
                // State might have changed during the async load operation —
                // except "currentTrack from eager snapshot" is expected state
                // and must NOT trip the fail-safe.
                if self.currentTrack != nil && !self.isEagerLoad {
                    print("[QueueManager] 🛡️ FAIL-SAFE 1: State changed during load - currentTrack now exists (user-driven): \(self.currentTrack!.title)")
                    return
                }

                if !self.playbackQueue.isEmpty {
                    print("[QueueManager] 🛡️ FAIL-SAFE 2: State changed during load - queue not empty (size: \(self.playbackQueue.count))")
                    return
                }

                if self.hasActiveSession {
                    print("[QueueManager] 🛡️ FAIL-SAFE 3: State changed during load - session now active")
                    return
                }

                // Reconcile with eager-load state. Four cases:
                //   (a) No eager track  → set queue's current index as current track, fire delegate.
                //   (b) Eager track IS in restored queue, index matches      → keep it, just populate queue.
                //   (c) Eager track IS in restored queue, index differs      → keep it, align queue index to it.
                //   (d) Eager track NOT in restored queue (library edit)     → drop eager, use queue's current, fire delegate.
                let eagerTrack: Song? = self.isEagerLoad ? self.currentTrack : nil
                let eagerIndexInRestored: Int? = eagerTrack.flatMap { et in
                    validTrackIDs.firstIndex(of: et.persistentID)
                }

                // Build the queue. If eager track is in the restored queue,
                // anchor currentIndex to its position rather than the stored
                // one (handles the case where the snapshot was written after
                // the queue file).
                let anchorIndex = eagerIndexInRestored ?? currentIndex

                playbackQueue = PlaybackQueue()
                playbackQueue.setTrackIDs(validTrackIDs, startingIndex: anchorIndex)
                playbackQueue.originalOrder = validOriginalOrder
                playbackQueue.isShuffled = shuffled

                self.isShuffled = shuffled
                self.isLooped = persisted.isLooped

                if let eager = eagerTrack, eagerIndexInRestored != nil {
                    // Cases (b) and (c): keep eager track, queue index aligned.
                    // Audio is already loaded via the eager path; no delegate call.
                    print("[QueueManager] ✅ Reconciled eager track with restored queue: \(eager.title) at index \(anchorIndex ?? -1)")
                    // restoredPlaybackPosition was already set during eager apply.
                } else if let index = anchorIndex, index < songs.count {
                    // Case (a) or (d): fall back to the queue's stored current.
                    // If there was an eager track (case d), we're dropping it
                    // and switching to the queue's current — fire delegate so
                    // audio engine picks up the new track.
                    //
                    // NOTE on case (d): the usual trigger is a legitimate
                    // save-race, not a bug. Snapshot writes are 500ms-
                    // debounced and fast-committed; the main queue save is
                    // debounced ~1s inside QueuePersistenceService. If the
                    // app is killed in the gap between those two commits,
                    // snapshot reflects a newer queue than the persisted
                    // one, so on next launch the eager track isn't in the
                    // restored (older) queue. Reconciliation drops eager,
                    // uses the queue's current — user sees a slightly
                    // older track but nothing's broken.
                    //
                    // The other case (d) trigger — library edit deleting
                    // the eager track — also takes this path and is also
                    // handled cleanly. Look at the log pattern across a
                    // session: a single hit is almost always save-race; a
                    // repeating pattern might indicate something worse.
                    let restored = songs[index]
                    if eagerTrack != nil {
                        print("[QueueManager] ⓘ Eager track not in restored queue — expected on save-race or library edit. Using queue's current: \(restored.title)")
                    }
                    self.currentTrack = restored
                    self.restoredPlaybackPosition = persisted.playbackPosition
                    self.delegate?.currentTrackDidChange(restored)
                    print("[QueueManager] ✅ Restored current track from persisted queue: \(restored.title) at position \(persisted.playbackPosition ?? 0)s")
                }

                // Eager state is now reconciled — future loadQueue calls go
                // back to the strict guards.
                self.isEagerLoad = false

                // Trigger @Published update by reassigning the struct
                playbackQueue = playbackQueue
                queueDidChange(triggeredBy: "loadQueue")

                print("[QueueManager] Loaded queue with \(validTrackIDs.count) tracks")
            }
        } else {
            print("[QueueManager] No persisted queue found, starting fresh")
        }
    }
}