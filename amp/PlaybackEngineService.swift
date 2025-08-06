import Foundation
import AVFoundation
import MediaPlayer
import UIKit

protocol PlaybackEngineDelegate: AnyObject {
    func playbackDidFinish(successfully: Bool)
    func playbackTimeDidUpdate(_ time: TimeInterval)
}

class PlaybackEngineService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    weak var delegate: PlaybackEngineDelegate?
    
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var volumeView: MPVolumeView?
    private var volumeObserver: NSKeyValueObservation?
    private var audioSessionConfigured = false
    private var lastPlayedSong: Song?
    private var pausedAt: TimeInterval = 0
    private var lastNowPlayingUpdate: TimeInterval = 0
    private var pauseCleanupTimer: Timer?
    
    @Published var isPlaying = false
    @Published var songDuration: TimeInterval = 0.0
    @Published var playbackTime: TimeInterval = 0.0
    @Published var currentOutputName: String = ""
    @Published var systemVolume: Float = 1.0
    
    override init() {
        super.init()
        updateCurrentOutputName()
        setupNotifications()
        updateSystemVolume()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        pauseCleanupTimer?.invalidate()
        volumeView?.removeFromSuperview()
        volumeObserver?.invalidate()
    }
    
    // MARK: - Playback Control
    
    func play(song: Song) {
        guard let url = getAudioURL(for: song) else {
            print("❌ No audio URL found for song: \(song.title)")
            return
        }
        
        // Cancel any pending cleanup since we're starting new playback
        cancelDelayedCleanup()
        
        // Track the song for memory management
        lastPlayedSong = song
        pausedAt = 0
        
        commonPlay(url: url)
        updateNowPlayingInfo(for: song)
    }
    
    func playPause() {
        if let player = player {
            // Player exists, normal pause/resume
            if player.isPlaying {
                player.pause()
                isPlaying = false
                stopTimer()
                // Update now playing info to reflect paused state
                updateNowPlayingInfoTime()
                // Schedule cleanup after extended pause (30 seconds) to save memory
                scheduleDelayedCleanup()
            } else {
                // Cancel any pending cleanup since we're resuming
                cancelDelayedCleanup()
                player.play()
                isPlaying = true
                startTimer()
                // Update now playing info to reflect playing state
                updateNowPlayingInfoTime()
            }
        } else if let song = lastPlayedSong {
            // Player was released due to memory optimization, reload and resume
            resumeFromPause(song: song, at: pausedAt)
        }
    }
    
    func stop() {
        player?.stop()
        isPlaying = false
        playbackTime = 0.0
        stopTimer()
        cancelDelayedCleanup()
        cleanupAudioResourcesOnStop()
        // Clear now playing info when stopping completely
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    func seek(to time: TimeInterval) {
        player?.currentTime = time
        playbackTime = time
        
        // Update now playing info with new elapsed time
        updateNowPlayingInfoTime()
    }
    
    func loadWithoutPlaying(song: Song) {
        guard let url = getAudioURL(for: song) else {
            print("❌ No audio URL found for song: \(song.title)")
            return
        }
        
        // Cancel any pending cleanup since we're loading new audio
        cancelDelayedCleanup()
        
        // Track the song for memory management
        lastPlayedSong = song
        pausedAt = 0
        
        commonLoad(url: url)
        updateNowPlayingInfo(for: song)
    }
    
    var hasAudioReady: Bool {
        return player != nil
    }
    
    // MARK: - Private Methods
    
    private func getAudioURL(for song: Song) -> URL? {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: song.persistentID),
            forProperty: MPMediaItemPropertyPersistentID
        )
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        
        guard let item = query.items?.first,
              let assetURL = item.assetURL else {
            return nil
        }
        
        return assetURL
    }
    
    private func getArtwork(for song: Song) -> MPMediaItemArtwork? {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: song.persistentID),
            forProperty: MPMediaItemPropertyPersistentID
        )
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        
        guard let item = query.items?.first else {
            return nil
        }
        
        return item.artwork
    }
    
    private func commonPlay(url: URL) {
        // Ensure audio session is configured before playing
        ensureAudioSessionConfigured()
        
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.volume = systemVolume // Apply current system volume
            
            songDuration = player?.duration ?? 0.0
            playbackTime = 0.0
            
            player?.play()
            isPlaying = true
            startTimer()
        } catch {
            print("❌ Failed to play audio: \(error)")
            isPlaying = false
        }
    }
    
    private func commonLoad(url: URL) {
        // Ensure audio session is configured before loading
        ensureAudioSessionConfigured()
        
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.volume = systemVolume // Apply current system volume
            
            songDuration = player?.duration ?? 0.0
            playbackTime = 0.0
            
            // Don't play, just load
            isPlaying = false
            stopTimer()
        } catch {
            print("❌ Failed to load audio: \(error)")
            isPlaying = false
        }
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.player else { return }
            
            self.playbackTime = player.currentTime
            self.delegate?.playbackTimeDidUpdate(player.currentTime)
            
            // Update now playing info every second to avoid excessive updates
            if player.currentTime - self.lastNowPlayingUpdate >= 1.0 {
                self.updateNowPlayingInfoTime()
                self.lastNowPlayingUpdate = player.currentTime
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func scheduleDelayedCleanup() {
        // Cancel any existing cleanup timer
        pauseCleanupTimer?.invalidate()
        
        // Schedule cleanup after 30 seconds of being paused
        pauseCleanupTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self = self, !self.isPlaying else { return }
            
            print("🧹 Starting delayed cleanup after 30s pause")
            self.cleanupAudioResourcesOnPause()
        }
    }
    
    private func cancelDelayedCleanup() {
        pauseCleanupTimer?.invalidate()
        pauseCleanupTimer = nil
    }
    
    private func cleanupAudioResourcesOnPause() {
        // When paused for memory optimization, we can release the audio player
        // but keep track of current position for seamless resume
        guard let player = player else { return }
        
        // Store current time for resume
        pausedAt = player.currentTime
        
        // Release the audio player to free memory
        self.player = nil
        
        // Keep the playback time for UI consistency  
        playbackTime = pausedAt
        
        // Deactivate audio session to free system resources
        deactivateAudioSessionIfNeeded()
        
        print("🧹 Audio resources cleaned up - paused at \(pausedAt)s to free memory")
    }
    
    private func cleanupAudioResourcesOnStop() {
        // Complete cleanup when stopping
        player = nil
        lastPlayedSong = nil
        pausedAt = 0
        songDuration = 0.0
        playbackTime = 0.0
        deactivateAudioSessionIfNeeded()
    }
    
    private func resumeFromPause(song: Song, at time: TimeInterval) {
        // Resume playback after memory optimization cleanup
        guard let url = getAudioURL(for: song) else {
            print("❌ Cannot resume - no audio URL found for song: \(song.title)")
            return
        }
        
        print("🔄 Resuming playback at \(time)s after memory cleanup")
        
        // Reload the audio
        commonPlay(url: url)
        
        // Seek to the paused position
        if time > 0 {
            player?.currentTime = time
            playbackTime = time
        }
        
        updateNowPlayingInfo(for: song)
    }
    
    private func deactivateAudioSessionIfNeeded() {
        // Only deactivate if we're not playing and configured
        guard !isPlaying && audioSessionConfigured else { return }
        
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionConfigured = false
            print("🔇 Audio session deactivated to free resources")
        } catch {
            print("⚠️ Failed to deactivate audio session: \(error)")
        }
    }
    
    private func updateNowPlayingInfo(for song: Song) {
        guard !song.title.isEmpty else {
            print("⚠️ Skipping now playing info update - empty song title")
            return
        }
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist.isEmpty ? "Unknown Artist" : song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album.isEmpty ? "Unknown Album" : song.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = max(0, songDuration)
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, playbackTime)
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        // Add artwork if available
        if let artwork = getArtwork(for: song) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            print("🎵 Updated now playing info: \(song.title) - \(song.artist) (\(self.playbackTime)s)")
        }
    }
    
    private func updateNowPlayingInfoTime() {
        // Update only time-sensitive properties without recreating the entire info
        guard var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            // If no info exists, we can't update just the time
            return
        }
        
        currentInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, playbackTime)
        currentInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
        }
    }
    
    // MARK: - Audio Session & Volume Management
    
    private func ensureAudioSessionConfigured() {
        guard !audioSessionConfigured else { return }
        
        do {
            let session = AVAudioSession.sharedInstance()
            
            print("🔊 Configuring audio session - Current Category: \(session.category.rawValue)")
            
            // Set category with options
            try session.setCategory(.playback, options: [.duckOthers, .allowBluetoothA2DP])
            
            // Activate the session
            try session.setActive(true)
            
            audioSessionConfigured = true
            print("✅ Audio session configured successfully")
        } catch let error as NSError {
            print("❌ Failed to configure audio session: \(error) - Code: \(error.code)")
            
            // Try a simpler approach if the full setup fails
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                audioSessionConfigured = true
                print("✅ Fallback audio session configured successfully")
            } catch {
                print("❌ Even fallback audio session setup failed: \(error)")
            }
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(handleRouteChange), 
            name: AVAudioSession.routeChangeNotification, 
            object: nil
        )
        
        // Set up volume monitoring using multiple approaches
        setupVolumeMonitoring()
        setupKVOVolumeMonitoring()
    }
    
    private func setupVolumeMonitoring() {
        // Create a hidden MPVolumeView to monitor system volume
        volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 0, height: 0))
        volumeView?.isHidden = true
        volumeView?.alpha = 0.0
        
        // Add to a window to make it functional
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.addSubview(volumeView!)
        }
        
        // Monitor the volume slider
        if let volumeSlider = volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider {
            volumeSlider.addTarget(self, action: #selector(handleVolumeChange), for: .valueChanged)
            systemVolume = volumeSlider.value
            player?.volume = systemVolume
        }
    }
    
    private func setupKVOVolumeMonitoring() {
        // Use KVO to observe AVAudioSession outputVolume changes
        let audioSession = AVAudioSession.sharedInstance()
        volumeObserver = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] session, change in
            DispatchQueue.main.async {
                self?.updateSystemVolume()
            }
        }
    }
    
    @objc private func handleRouteChange() {
        updateCurrentOutputName()
        updateSystemVolume()
    }
    
    @objc private func handleVolumeChange() {
        updateSystemVolume()
    }
    
    private func updateSystemVolume() {
        if let volumeSlider = volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider {
            systemVolume = volumeSlider.value
        } else {
            // Fallback to AVAudioSession
            let session = AVAudioSession.sharedInstance()
            systemVolume = session.outputVolume
        }
        
        print("🔊 System volume updated: \(systemVolume)")
        
        // Apply system volume to player to handle Bluetooth floor issue
        player?.volume = systemVolume
        
        // Log player volume for debugging
        if let playerVolume = player?.volume {
            print("🎵 Player volume set to: \(playerVolume)")
        }
    }
    
    private func updateCurrentOutputName() {
        let session = AVAudioSession.sharedInstance()
        if let currentRoute = session.currentRoute.outputs.first {
            currentOutputName = currentRoute.portName
        } else {
            currentOutputName = "iPhone"
        }
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopTimer()
        delegate?.playbackDidFinish(successfully: flag)
    }
}