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
    @Published var currentTrack: Song?
    @Published var isShuffled = false
    
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
    }
    
    private var sessionState: SessionState = .idle
    private var sessionStartTime: Date?
    private var lastUserInteraction = Date()
    private var hasActiveSession = false
    
    init() {
        self.isShuffled = UserDefaults.standard.bool(forKey: "shuffleOnStart")
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
        
        guard let track = playbackQueue.next() else { return nil }
        
        // Trigger @Published update by reassigning the struct
        playbackQueue = playbackQueue
        currentTrack = track
        queueDidChange(triggeredBy: "nextTrack")
        saveQueue()
        delegate?.currentTrackDidChange(track)
        
        return track
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
        print("[QueueManager] Session paused")
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
        sessionState = .background
        print("[QueueManager] Entered background")
        saveQueue()
    }
    
    func enterForeground() {
        if sessionState == .background {
            sessionState = hasActiveSession ? .active : .idle
            print("[QueueManager] Entered foreground - session state: \(sessionState)")
        }
        // Don't reload queue!
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
        print("[QueueManager] Saving queue - will NOT reload after save")
        
        Task {
            let persisted = PersistedQueue(
                savedAt: Date(),
                trackIDs: playbackQueue.getAllTrackIDs(),
                currentIndex: playbackQueue.currentIndex,
                isShuffled: isShuffled,
                originalOrder: playbackQueue.originalOrder,
                checksum: generateChecksum()
            )
            await persistenceService.saveQueue(persisted)
            
            print("[QueueManager] Queue saved successfully")
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
        
        // Don't load if user interacted recently (within 30 seconds)
        let timeSinceInteraction = Date().timeIntervalSince(lastUserInteraction)
        guard timeSinceInteraction > 30 else {
            print("[QueueManager] ⛔ BLOCKED: Attempted to load queue \(Int(timeSinceInteraction))s after user interaction")
            return
        }
        
        // Don't load if we have a current track (active or paused playback)
        guard currentTrack == nil else {
            print("[QueueManager] ⛔ BLOCKED: Not loading - track is active")
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
                // Restore the queue state
                playbackQueue = PlaybackQueue()
                playbackQueue.setTrackIDs(validTrackIDs, startingIndex: currentIndex)
                playbackQueue.originalOrder = validOriginalOrder
                playbackQueue.isShuffled = shuffled
                
                // Update published properties
                self.isShuffled = shuffled
                
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