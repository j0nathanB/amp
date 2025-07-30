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
    
    func startPlayback(from songs: [Song], startingWith startSong: Song) {
      playbackQueue.setTracks(songs, startingWith: startSong)
      if isShuffled {
          playbackQueue.shuffle(keepCurrentFirst: true)
      }
      saveQueue()
      if let track = playbackQueue.currentTrack {
          self.currentTrack = track
          playCurrentTrackAudio()
      }
  }

    func playTrack(at index: Int) {
        guard let song = playbackQueue.play(at: index) else { return }
        
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
          self.currentTrack = track
          playCurrentTrackAudio()
          saveQueue()
      }
  }

    func previousTrack() {
      if let track = playbackQueue.previous() {
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
      private(set) var tracks: [Song]
      private(set) var currentIndex: Int?
      private(set) var originalOrder: [Song] // For unshuffle functionality
      private(set) var isShuffled: Bool = false

      // MARK: - Initialization
      init(tracks: [Song] = [], startingIndex: Int? = nil) {
          self.tracks = tracks
          self.currentIndex = startingIndex
          self.originalOrder = tracks
      }

      // MARK: - Queue Management
      mutating func setTracks(_ newTracks: [Song], startingWith startSong: Song? = nil) {
          self.tracks = newTracks
          self.originalOrder = newTracks
          self.currentIndex = startSong.flatMap { song in
              newTracks.firstIndex(of: song)
          }
      }

      mutating func play(at index: Int) -> Song? {
          guard index >= 0 && index < tracks.count else { return nil }
          currentIndex = index
          return tracks[index]
      }

      mutating func next() -> Song? {
          guard let current = currentIndex,
                current + 1 < tracks.count else { return nil }

          return play(at: current + 1)
      }

      mutating func previous() -> Song? {
          guard let current = currentIndex,
                current - 1 >= 0 else { return nil }

          return play(at: current - 1)
      }

      mutating func shuffle(keepCurrentFirst: Bool = true) {
          guard !tracks.isEmpty else { return }

          if keepCurrentFirst, let currentIdx = currentIndex {
              let currentSong = tracks[currentIdx]
              var remainingTracks = tracks
              remainingTracks.remove(at: currentIdx)
              remainingTracks.shuffle()

              tracks = [currentSong] + remainingTracks
              currentIndex = 0
          } else {
              tracks.shuffle()
              if !tracks.isEmpty && currentIndex == nil {
                  currentIndex = 0
              }
          }

          isShuffled = true
      }

      mutating func unshuffle() {
          tracks = originalOrder
          isShuffled = false

          // Try to maintain current track position
          if let currentIdx = currentIndex,
             currentIdx < tracks.count {
              let currentSong = tracks[currentIdx]
              currentIndex = originalOrder.firstIndex(of: currentSong)
          }

          // Position updated above
      }

      mutating func clear() {
          tracks.removeAll()
          currentIndex = nil
          originalOrder.removeAll()
          isShuffled = false
      }

      // MARK: - Computed Properties
      var currentTrack: Song? {
          guard let index = currentIndex,
                index >= 0 && index < tracks.count else { return nil }
          return tracks[index]
      }

      var hasNext: Bool {
          guard let current = currentIndex else { return false }
          return current + 1 < tracks.count
      }

      var hasPrevious: Bool {
          guard let current = currentIndex else { return false }
          return current > 0
      }

      var isEmpty: Bool {
          return tracks.isEmpty
      }

      var count: Int {
          return tracks.count
      }

  }

  // MARK: - Persistence Support
  extension PlaybackQueue {
      func persistableData() -> [MPMediaEntityPersistentID] {
          return tracks.map { $0.persistentID }
      }

      mutating func restore(from persistentIDs: [MPMediaEntityPersistentID], 
                           using libraryService: LibraryService) {
          let restoredTracks = persistentIDs.compactMap {
              libraryService.getSong(by: $0)
          }
          self.tracks = restoredTracks
          self.originalOrder = restoredTracks
      }
  }