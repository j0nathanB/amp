import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI

class AudioPlayerService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerService()
    
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let queueUserDefaultsKey = "savedPlaybackQueueIDs"
    
    @Published private(set) var playbackQueue = PlaybackQueue()
    @Published private(set) var queueVersion = 0 // Trigger UI updates when queue changes
    @Published var isPlaying = false
    @Published var currentTrack: Song?
    @Published var songDuration: TimeInterval = 0.0
    @Published var playbackTime: TimeInterval = 0.0
    @Published var isShuffled = false
    @Published var selectedTab: Tab = .queue
    @Published var currentOutputName: String = ""
    
    private override init() {
        super.init()
        self.isShuffled = UserDefaults.standard.bool(forKey: "shuffleOnStart")
        self.loadQueue()
        self.updateCurrentOutputName()
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    // MARK: - Public Playback Control
    
    private func queueDidChange() {
        queueVersion += 1
    }
    
    func startPlayback(from songs: [Song], startingWith startSong: Song) {
      playbackQueue.setTracks(songs, startingWith: startSong)
      if isShuffled {
          playbackQueue.shuffle(keepCurrentFirst: true)
      }
      queueDidChange()
      saveQueue()
      if let track = playbackQueue.getCurrentTrack() {
          self.currentTrack = track
          playCurrentTrackAudio()
      }
  }

    func playTrack(at index: Int) {
        guard let song = playbackQueue.play(at: index) else { return }
        
        queueDidChange() // Trigger UI update for current index change
        self.currentTrack = song
        
        DispatchQueue.main.async {
            self.selectedTab = .nowPlaying
        }
        
        Task {
            let predicate = MPMediaPropertyPredicate(value: NSNumber(value: song.persistentID), forProperty: MPMediaItemPropertyPersistentID)
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            
            guard let item = query.items?.first, let url = item.assetURL else {
                print("ERROR: Could not find song or its URL for \(song.title)")
                return
            }
            
            await MainActor.run {
                self.commonPlay(url: url)
                self.updateNowPlayingInfo(for: item)
            }
        }
    }
    
    func playPause() {
        guard player != nil else { return }
        if isPlaying {
            player?.pause()
            self.invalidateTimer()
        } else {
            player?.play()
            self.startTimer()
        }
        isPlaying.toggle()
    }
    
    func nextTrack() {
      if let track = playbackQueue.next() {
          queueDidChange() // Trigger UI update for current index change
          self.currentTrack = track
          playCurrentTrackAudio()
          saveQueue()
      }
  }

    func previousTrack() {
      if let track = playbackQueue.previous() {
          queueDidChange() // Trigger UI update for current index change
          self.currentTrack = track
          playCurrentTrackAudio()
          saveQueue()
      }
  }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        self.playbackTime = time
    }

    func shuffleCurrentQueue() {
        playbackQueue.shuffle(keepCurrentFirst: true)
        queueDidChange()
        self.saveQueue()
    }

    // MARK: - Internal Logic & Helpers
    
    private func playCurrentTrackAudio() {
        guard let song = currentTrack else { return }
        
        DispatchQueue.main.async {
            self.selectedTab = .nowPlaying
        }
        
        Task {
            let predicate = MPMediaPropertyPredicate(value: NSNumber(value: song.persistentID), forProperty: MPMediaItemPropertyPersistentID)
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            
            guard let item = query.items?.first, let url = item.assetURL else {
                print("ERROR: Could not find song or its URL for \(song.title)")
                return
            }
            
            await MainActor.run {
                self.commonPlay(url: url)
                self.updateNowPlayingInfo(for: item)
            }
        }
    }

    private func commonPlay(url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
            self.isPlaying = true
            self.songDuration = player?.duration ?? 0.0
            startTimer()
        } catch {
            print("Error playing audio: \(error.localizedDescription)")
            self.isPlaying = false
        }
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag { nextTrack() }
    }
    
    private func startTimer() {
        invalidateTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.player != nil else { return }
            self.playbackTime = self.player!.currentTime
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func saveQueue() {
        let queueIDs = playbackQueue.persistableData()
        UserDefaults.standard.set(queueIDs, forKey: queueUserDefaultsKey)
    }

    private func loadQueue() {
        guard let savedIDs = UserDefaults.standard.array(forKey: queueUserDefaultsKey) as? [MPMediaEntityPersistentID] else { return }
        Task {
            await MainActor.run {
                self.playbackQueue.restore(from: savedIDs, using: LibraryService.shared)
                self.queueDidChange()
            }
        }
    }
    
    var currentTrackArtwork: MPMediaItemArtwork? {
        guard let track = currentTrack else { return nil }
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: track.persistentID), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        return query.items?.first?.artwork
    }
    
    private func updateNowPlayingInfo(for item: MPMediaItem) {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = item.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = item.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = item.albumTitle
        if let artwork = item.artwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player?.currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = player?.duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    @objc private func updateCurrentOutputName() {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        if let output = currentRoute.outputs.first {
            self.currentOutputName = output.portName
        }
    }
    
    @objc private func handleRouteChange() {
        updateCurrentOutputName()
    }
}
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
    
    // MARK: - Song Access (with caching) - removed duplicate
    
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
}

// MARK: - Persistence Support
extension PlaybackQueue {
    func persistableData() -> [MPMediaEntityPersistentID] {
        return trackIDs
    }
    
    mutating func restore(from persistentIDs: [MPMediaEntityPersistentID], 
                         using libraryService: LibraryService) {
        setTrackIDs(persistentIDs)
    }
}