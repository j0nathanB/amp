import Foundation
import SwiftUI

class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()
    
    // Services
    private let playbackEngine = PlaybackEngineService()
    private let queueManager = QueueManagerService()
    private let navigation = NavigationService()
    
    // Public interface - delegate to services
    @Published var isPlaying = false
    @Published var currentTrack: Song?
    @Published var songDuration: TimeInterval = 0.0
    @Published var playbackTime: TimeInterval = 0.0
    @Published var currentOutputName: String = ""
    @Published var isShuffled = false
    @Published var selectedTab: Tab = .queue
    
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
        
        // Bind queue manager properties
        queueManager.$currentTrack
            .assign(to: &$currentTrack)
        
        queueManager.$isShuffled
            .assign(to: &$isShuffled)
        
        // Bind navigation properties
        navigation.$selectedTab
            .assign(to: &$selectedTab)
    }
    
    // MARK: - Public API (same as before)
    
    func startPlayback(from songs: [Song], startingWith startSong: Song) {
        queueManager.startPlayback(from: songs, startingWith: startSong)
        // currentTrackDidChange will be called via delegate
    }
    
    func playTrack(at index: Int) {
        if let track = queueManager.playTrack(at: index) {
            playbackEngine.play(song: track)
            navigation.navigateToNowPlaying()
        }
    }
    
    func playPause() {
        playbackEngine.playPause()
    }
    
    func nextTrack() {
        if let track = queueManager.nextTrack() {
            playbackEngine.play(song: track)
        }
    }
    
    func previousTrack() {
        if let track = queueManager.previousTrack() {
            playbackEngine.play(song: track)
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
    
    // MARK: - Navigation
    
    func navigateToNowPlaying() {
        navigation.navigateToNowPlaying()
    }
    
    func navigateToQueue() {
        navigation.navigateToQueue()
    }
}

// MARK: - PlaybackEngineDelegate

extension AudioPlayerService: PlaybackEngineDelegate {
    func playbackDidFinish(successfully: Bool) {
        if successfully {
            nextTrack()
        }
    }
    
    func playbackTimeDidUpdate(_ time: TimeInterval) {
        // Already bound via Combine, but could add additional logic here
    }
}

// MARK: - QueueManagerDelegate

extension AudioPlayerService: QueueManagerDelegate {
    func queueDidChange() {
        // Trigger UI updates - objectWillChange is automatically called
        // due to @Published properties in queueManager
    }
    
    func currentTrackDidChange(_ track: Song?) {
        // Play the new track if there is one
        if let track = track {
            playbackEngine.play(song: track)
        }
    }
}