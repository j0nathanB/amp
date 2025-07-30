import Foundation
import MediaPlayer

struct PlaybackQueue {
    // MARK: - Properties
    private(set) var trackIDs: [MPMediaEntityPersistentID]
    private(set) var currentIndex: Int?
    private(set) var originalOrder: [MPMediaEntityPersistentID] // For unshuffle functionality
    private(set) var isShuffled: Bool = false
    
    // Cache for recently accessed tracks (limit to 50 to prevent memory buildup)
    private var songCache: [MPMediaEntityPersistentID: Song] = [:]
    private let maxCacheSize = 50
    
    // MARK: - Initialization
    init(trackIDs: [MPMediaEntityPersistentID] = [], startingIndex: Int? = nil) {
        self.trackIDs = trackIDs
        self.currentIndex = startingIndex
        self.originalOrder = trackIDs
    }
    
    // MARK: - Queue Management
    mutating func setTrackIDs(_ newTrackIDs: [MPMediaEntityPersistentID], startingIndex: Int? = nil) {
        self.trackIDs = newTrackIDs
        self.originalOrder = newTrackIDs
        self.currentIndex = startingIndex
        // Clear cache when setting new tracks
        self.songCache.removeAll()
    }
    
    mutating func setTracks(_ newTracks: [Song], startingWith startSong: Song? = nil) {
        let newTrackIDs = newTracks.map { $0.persistentID }
        let startingIndex = startSong.flatMap { song in
            newTrackIDs.firstIndex(of: song.persistentID)
        }
        setTrackIDs(newTrackIDs, startingIndex: startingIndex)
        
        // Pre-cache the provided songs
        for song in newTracks.prefix(maxCacheSize) {
            songCache[song.persistentID] = song
        }
    }
    
    mutating func play(at index: Int) -> Song? {
        guard index >= 0 && index < trackIDs.count else { return nil }
        currentIndex = index
        return getSong(at: index)
    }
    
    mutating func next() -> Song? {
        guard let current = currentIndex,
              current + 1 < trackIDs.count else { return nil }
        
        return play(at: current + 1)
    }
    
    mutating func previous() -> Song? {
        guard let current = currentIndex,
              current - 1 >= 0 else { return nil }
        
        return play(at: current - 1)
    }
    
    mutating func shuffle(keepCurrentFirst: Bool = true) {
        guard !trackIDs.isEmpty else { return }
        
        if keepCurrentFirst, let currentIdx = currentIndex {
            let currentTrackID = trackIDs[currentIdx]
            var remainingTrackIDs = trackIDs
            remainingTrackIDs.remove(at: currentIdx)
            remainingTrackIDs.shuffle()
            
            trackIDs = [currentTrackID] + remainingTrackIDs
            currentIndex = 0
        } else {
            trackIDs.shuffle()
            if !trackIDs.isEmpty && currentIndex == nil {
                currentIndex = 0
            }
        }
        
        isShuffled = true
    }
    
    mutating func unshuffle() {
        trackIDs = originalOrder
        isShuffled = false
        
        // Try to maintain current track position
        if let currentIdx = currentIndex,
           currentIdx < trackIDs.count {
            let currentTrackID = trackIDs[currentIdx]
            currentIndex = originalOrder.firstIndex(of: currentTrackID)
        }
    }
    
    mutating func clear() {
        trackIDs.removeAll()
        currentIndex = nil
        originalOrder.removeAll()
        isShuffled = false
        songCache.removeAll()
    }
    
    // MARK: - Computed Properties
    mutating func getCurrentTrack() -> Song? {
        guard let index = currentIndex else { return nil }
        return getSong(at: index)
    }
    
    var hasNext: Bool {
        guard let current = currentIndex else { return false }
        return current + 1 < trackIDs.count
    }
    
    var hasPrevious: Bool {
        guard let current = currentIndex else { return false }
        return current > 0
    }
    
    var isEmpty: Bool {
        return trackIDs.isEmpty
    }
    
    var count: Int {
        return trackIDs.count
    }
    
    // MARK: - Access specific tracks for UI (lazy loading)
    mutating func getSong(at index: Int) -> Song? {
        guard index >= 0 && index < trackIDs.count else { return nil }
        
        let trackID = trackIDs[index]
        
        // Check cache first
        if let cachedSong = songCache[trackID] {
            return cachedSong
        }
        
        // Load from library
        if let song = LibraryService.shared.getSong(by: trackID) {
            // Add to cache, managing size
            if songCache.count >= maxCacheSize {
                // Remove oldest entry (simple FIFO)
                if let firstKey = songCache.keys.first {
                    songCache.removeValue(forKey: firstKey)
                }
            }
            songCache[trackID] = song
            return song
        }
        
        return nil
    }
    
    // Get track ID at index (fast, no loading needed)
    func getTrackID(at index: Int) -> MPMediaEntityPersistentID? {
        guard index >= 0 && index < trackIDs.count else { return nil }
        return trackIDs[index]
    }
    
    // Get all track IDs for persistence
    func getAllTrackIDs() -> [MPMediaEntityPersistentID] {
        return trackIDs
    }
}

// MARK: - Persistence Support
extension PlaybackQueue {
    func persistableData() -> [MPMediaEntityPersistentID] {
        return trackIDs
    }
    
    mutating func restore(from persistentIDs: [MPMediaEntityPersistentID], currentIndex: Int) {
        setTrackIDs(persistentIDs, startingIndex: currentIndex)
    }
}