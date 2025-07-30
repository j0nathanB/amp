import Foundation
import MediaPlayer

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
    
    private let queueUserDefaultsKey = "savedPlaybackQueueIDs"
    
    init() {
        self.isShuffled = UserDefaults.standard.bool(forKey: "shuffleOnStart")
        loadQueue()
    }
    
    // MARK: - Queue Management
    
    func startPlayback(from songs: [Song], startingWith startSong: Song) {
        playbackQueue.setTracks(songs, startingWith: startSong)
        if isShuffled {
            playbackQueue.shuffle(keepCurrentFirst: true)
        }
        queueDidChange()
        saveQueue()
        
        if let track = playbackQueue.getCurrentTrack() {
            self.currentTrack = track
            delegate?.currentTrackDidChange(track)
        }
    }
    
    func playTrack(at index: Int) -> Song? {
        guard let track = playbackQueue.play(at: index) else { return nil }
        
        currentTrack = track
        queueDidChange()
        saveQueue()
        delegate?.currentTrackDidChange(track)
        
        return track
    }
    
    func nextTrack() -> Song? {
        guard let track = playbackQueue.next() else { return nil }
        
        currentTrack = track
        queueDidChange()
        saveQueue()
        delegate?.currentTrackDidChange(track)
        
        return track
    }
    
    func previousTrack() -> Song? {
        guard let track = playbackQueue.previous() else { return nil }
        
        currentTrack = track
        queueDidChange()
        saveQueue()
        delegate?.currentTrackDidChange(track)
        
        return track
    }
    
    func shuffleCurrentQueue() {
        playbackQueue.shuffle(keepCurrentFirst: true)
        queueDidChange()
        saveQueue()
    }
    
    func toggleShuffle() {
        isShuffled.toggle()
        UserDefaults.standard.set(isShuffled, forKey: "shuffleOnStart")
        
        if isShuffled {
            playbackQueue.shuffle(keepCurrentFirst: true)
        } else {
            // Restore original order (would need to store original order)
            // For now, just keep current state
        }
        queueDidChange()
        saveQueue()
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
    
    // MARK: - Private Methods
    
    private func queueDidChange() {
        queueVersion += 1
        delegate?.queueDidChange()
    }
    
    private func saveQueue() {
        let trackIDs = playbackQueue.getAllTrackIDs()
        UserDefaults.standard.set(trackIDs, forKey: queueUserDefaultsKey)
    }
    
    private func loadQueue() {
        guard let savedIDs = UserDefaults.standard.array(forKey: queueUserDefaultsKey) as? [MPMediaEntityPersistentID],
              !savedIDs.isEmpty else {
            return
        }
        
        // Load songs from saved IDs
        var songs: [Song] = []
        for id in savedIDs {
            if let song = LibraryService.shared.getSong(by: id) {
                songs.append(song)
            }
        }
        
        guard !songs.isEmpty else { return }
        
        playbackQueue.restore(from: savedIDs, currentIndex: 0)
        if let firstSong = songs.first {
            currentTrack = firstSong
        }
        
        queueDidChange()
    }
}