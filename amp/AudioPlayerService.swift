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
    @Published var currentIndex: Int = -1
    @Published var systemVolume: Float = 1.0
    
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
        
        playbackEngine.$systemVolume
            .assign(to: &$systemVolume)
        
        // Bind queue manager properties
        queueManager.$currentTrack
            .assign(to: &$currentTrack)
        
        queueManager.$isShuffled
            .assign(to: &$isShuffled)
        
        // Bind navigation properties
        navigation.$selectedTab
            .assign(to: &$selectedTab)
        
        // Bind currentIndex from playbackQueue changes
        queueManager.$playbackQueue
            .map { $0.currentIndex ?? -1 }
            .assign(to: &$currentIndex)
    }
    
    // MARK: - Public API (same as before)
    
    func startPlayback(from songs: [Song], startingWith startSong: Song) {
        queueManager.startPlayback(from: songs, startingWith: startSong)
        navigation.navigateToNowPlaying()
        // Explicitly start playing the selected song
        if let track = currentTrack {
            playbackEngine.play(song: track)
        }
    }
    
    func playTrack(at index: Int) {
        if let track = queueManager.playTrack(at: index) {
            playbackEngine.play(song: track)
            navigation.navigateToNowPlaying()
        }
    }
    
    func playPause() {
        // If no audio is loaded but we have a current track, load and play it
        if currentTrack != nil && !isPlaying && !playbackEngine.hasAudioReady {
            if let track = currentTrack {
                playbackEngine.play(song: track)
            }
        } else {
            playbackEngine.playPause()
        }
    }
    
    func nextTrack() {
        if let track = queueManager.nextTrack() {
            if isPlaying {
                playbackEngine.play(song: track)
            } else {
                // If paused, just load the track without playing
                playbackEngine.loadWithoutPlaying(song: track)
            }
        }
    }
    
    func previousTrack() {
        if let track = queueManager.previousTrack() {
            if isPlaying {
                playbackEngine.play(song: track)
            } else {
                // If paused, just load the track without playing
                playbackEngine.loadWithoutPlaying(song: track)
            }
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
            // When a track finishes, automatically play the next track
            if let track = queueManager.nextTrack() {
                playbackEngine.play(song: track)
            }
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
        // Load the new track, but only play if we were already playing
        if let track = track {
            if isPlaying {
                playbackEngine.play(song: track)
            } else {
                playbackEngine.loadWithoutPlaying(song: track)
            }
        }
    }
}