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
    @Published var currentTrack: Song? {
        didSet {
            // Debug logging to track when currentTrack changes
            if let old = oldValue, let new = currentTrack {
                if old.persistentID != new.persistentID {
                    print("🎵 [QueueManager] currentTrack changed: '\(old.title)' → '\(new.title)'")
                }
            } else if let new = currentTrack {
                print("🎵 [QueueManager] currentTrack set: '\(new.title)'")
            } else {
                print("🎵 [QueueManager] currentTrack cleared")
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
    
    func playTrack(at index: Int) -> Song? {
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
        
        playbackQueue.shuffle(keepCurrentFirst: true)
        // Trigger @Published update by reassigning the struct
        playbackQueue = playbackQueue
        queueDidChange(triggeredBy: "shuffle")
        saveQueue()
        
        // Clear flag after operation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.isPerformingOperation = false
            print("[QueueManager] Shuffle operation complete")
        }
    }
    
    func toggleShuffle() {
        print("[QueueManager] Toggling shuffle to: \(!isShuffled)")
        isPerformingOperation = true
        
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
        
        // Clear flag after operation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.isPerformingOperation = false
            print("[QueueManager] Toggle shuffle operation complete")
        }
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
    }
    
    func enterBackground() {
        stateBeforeBackground = sessionState
        sessionState = .background
        print("[QueueManager] Entered background - saved previous state: \(stateBeforeBackground?.description ?? "nil")")
        saveQueue()
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
            checksum: generateChecksum()
        )

        // Now persist asynchronously with the already-captured state
        Task {
            await persistenceService.saveQueue(persisted)
            print("[QueueManager] Queue saved successfully - index: \(persisted.currentIndex ?? -1)")
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
    }
    
    internal func loadQueue() async {
        // Log entry to loadQueue with current state
        print("⚠️ [QueueManager] loadQueue() ENTERED - currentTrack: \(currentTrack?.title ?? "nil"), queueSize: \(playbackQueue.count), hasActiveSession: \(hasActiveSession)")

        // CRITICAL SAFETY CHECK: Never load queue if there's ANY sign of active playback

        // Check 1: Never load if we have a current track
        if currentTrack != nil {
            print("[QueueManager] 🛡️ PROTECTION 1: Refusing load - current track exists: \(currentTrack?.title ?? "unknown")")
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
        guard currentTrack == nil else {
            print("[QueueManager] ⛔ BLOCKED: Not loading - track is active: \(currentTrack?.title ?? "unknown")")
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
            // Filter out any tracks that no longer exist in the library
            let validTrackIDs: [MPMediaEntityPersistentID] = persisted.trackIDs.compactMap { id in
                LibraryService.shared.getSong(by: id) != nil ? id : nil
            }
            
            guard !validTrackIDs.isEmpty else {
                print("[QueueManager] No valid tracks found in persisted queue")
                return
            }
            
            let songs: [Song] = validTrackIDs.compactMap { id in
                LibraryService.shared.getSong(by: id)
            }
            
            let validOriginalOrder = persisted.originalOrder.filter { validTrackIDs.contains($0) }
            let shuffled = persisted.isShuffled
            let currentIndex = persisted.currentIndex
            
            await MainActor.run {
                // CRITICAL FAIL-SAFE: Check state again before mutating queue
                // State might have changed during the async load operation
                if self.currentTrack != nil {
                    print("[QueueManager] 🛡️ FAIL-SAFE 1: State changed during load - currentTrack now exists: \(self.currentTrack!.title)")
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

                // Restore the queue state
                playbackQueue = PlaybackQueue()
                playbackQueue.setTrackIDs(validTrackIDs, startingIndex: currentIndex)
                playbackQueue.originalOrder = validOriginalOrder
                playbackQueue.isShuffled = shuffled

                // Update published properties
                self.isShuffled = shuffled
                self.isLooped = persisted.isLooped

                // Set current track if we have a valid index
                if let index = currentIndex,
                   index < songs.count {
                    self.currentTrack = songs[index]
                }

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