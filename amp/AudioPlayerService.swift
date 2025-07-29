import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI

class AudioPlayerService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerService()
    
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let queueUserDefaultsKey = "savedPlaybackQueueIDs"
    
    @Published var queue: [Song] = []
    @Published var currentQueueIndex: Int?
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
        var finalQueue = songs
        if self.isShuffled {
            finalQueue = songs.shuffled()
            if let index = finalQueue.firstIndex(of: startSong) {
                finalQueue.swapAt(0, index)
            }
        }
        guard let index = finalQueue.firstIndex(of: startSong) else { return }
        
        self.queue = finalQueue
        self.saveQueue()
        self.playTrack(at: index)
    }

    func playTrack(at index: Int) {
        guard index >= 0 && index < queue.count else { return }
        
        self.currentQueueIndex = index
        let song = queue[index]
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
        guard let currentIndex = currentQueueIndex, (currentIndex + 1) < queue.count else { return }
        playTrack(at: currentIndex + 1)
    }

    func previousTrack() {
        guard let currentIndex = currentQueueIndex, (currentIndex - 1) >= 0 else { return }
        playTrack(at: currentIndex - 1)
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        self.playbackTime = time
    }

    func shuffleCurrentQueue() {
        guard !queue.isEmpty else { return }
        if let currentIndex = currentQueueIndex {
            var songsToShuffle = self.queue
            let currentSong = songsToShuffle.remove(at: currentIndex)
            songsToShuffle.shuffle()
            self.queue = [currentSong] + songsToShuffle
            self.currentQueueIndex = 0
        } else {
            self.queue.shuffle()
        }
        self.saveQueue()
    }

    // MARK: - Internal Logic & Helpers

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
        let queueIDs = queue.map { $0.persistentID }
        UserDefaults.standard.set(queueIDs, forKey: queueUserDefaultsKey)
    }

    private func loadQueue() {
        guard let savedIDs = UserDefaults.standard.array(forKey: queueUserDefaultsKey) as? [MPMediaEntityPersistentID] else { return }
        Task {
            let savedQueue = savedIDs.compactMap { LibraryService.shared.getSong(by: $0) }
            await MainActor.run {
                self.queue = savedQueue
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
