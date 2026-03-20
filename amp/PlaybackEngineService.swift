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
    
    // Track resume operations to suppress notifications
    private var isResumingFromPause = false

    // Track consecutive load failures to prevent infinite skip loops
    private var consecutiveLoadFailures = 0
    private let maxConsecutiveFailures = 5

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
        // Ensure audio session is configured before setting up remote commands
        ensureAudioSessionConfigured()
        setupRemoteCommandCenter()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        pauseCleanupTimer?.invalidate()
        volumeView?.removeFromSuperview()
        volumeObserver?.invalidate()
        teardownRemoteCommandCenter()
    }
    
    // MARK: - Playback Control
    
    func play(song: Song, isManualSelection: Bool = false) {
        guard let url = getAudioURL(for: song) else {
            print("❌ No audio URL found for song: \(song.title)")
            return
        }
        
        // Check if this is the same song being resumed
        let isSameSong = lastPlayedSong?.persistentID == song.persistentID
        let storedPausePosition = pausedAt
        
        // Track the song for memory management
        lastPlayedSong = song
        
        // CRITICAL FIX: Only reset pausedAt if this is a genuinely new song
        if !isSameSong {
            pausedAt = 0
            print("🎵 Playing new song: \(song.title)")
        } else {
            print("🎵 Resuming same song: \(song.title) from position \(storedPausePosition)s")
        }
        
        // Cancel any pending cleanup since we're starting new playback
        cancelDelayedCleanup()
        
        commonPlay(url: url)
        
        // If resuming same song, determine the correct position to resume from
        if isSameSong {
            // Check if user has manually sought to a different position
            let hasManuallySeeeked = abs(playbackTime - storedPausePosition) > 0.1 // 0.1s tolerance
            let resumePosition = hasManuallySeeeked ? playbackTime : storedPausePosition
            
            if resumePosition > 0 {
                player?.currentTime = resumePosition
                playbackTime = resumePosition
                if hasManuallySeeeked {
                    print("✅ Resuming from manual seek position: \(resumePosition)s")
                } else {
                    print("✅ Resuming from stored pause position: \(resumePosition)s")
                }
            }
        }
        
        updateNowPlayingInfo(for: song)
        
        // Schedule notification for track change
        scheduleTrackChangeNotification(for: song, isManualSelection: isManualSelection)
    }
    
    func playPause() {
        if let player = player {
            // Player exists, normal pause/resume
            if player.isPlaying {
                // CRITICAL FIX: Store current playback position BEFORE pausing
                pausedAt = player.currentTime
                print("⏸️ Pausing at position: \(pausedAt)s")

                player.pause()
                isPlaying = false
                stopTimer()
                // Update now playing info to reflect paused state
                updateNowPlayingInfoTime()
                // Schedule cleanup after 30 seconds to free memory during long pauses
                scheduleDelayedCleanup()
            } else {
                // Mark this as a resume, not a new track
                isResumingFromPause = true

                // CRITICAL FIX: Determine the correct position to resume from
                let hasManuallySeeeked = abs(playbackTime - pausedAt) > 0.1 // 0.1s tolerance
                let resumePosition = hasManuallySeeeked ? playbackTime : pausedAt

                if resumePosition > 0 {
                    player.currentTime = resumePosition
                    playbackTime = resumePosition
                    if hasManuallySeeeked {
                        print("▶️ Resuming from manual seek position: \(resumePosition)s")
                    } else {
                        print("▶️ Resuming from stored pause position: \(resumePosition)s")
                    }
                } else {
                    print("▶️ Resuming from current position: \(player.currentTime)s")
                }

                player.play()
                isPlaying = true
                startTimer()
                // Cancel any pending cleanup since we're resuming
                cancelDelayedCleanup()
                // Update now playing info to reflect playing state
                updateNowPlayingInfoTime()
                isResumingFromPause = false
            }
        } else if let song = lastPlayedSong {
            // Player was released, reload and resume (fallback case)
            print("🔄 Entering resume path - song: \(song.title), pausedAt: \(pausedAt)s")
            isResumingFromPause = true
            resumeFromPause(song: song, at: pausedAt)
            isResumingFromPause = false
        } else {
            // No audio loaded at all - cannot play/pause
            print("⚠️ PlayPause called but no audio is loaded. Use play(song:) to start playback.")
        }
    }
    
    func stop() {
        player?.stop()
        isPlaying = false
        playbackTime = 0.0
        stopTimer()
        cleanupAudioResourcesOnStop()
        // Clear now playing info when stopping completely
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            print("🧹 Cleared Now Playing info after stop")
        }
    }
    
    func seek(to time: TimeInterval) {
        player?.currentTime = time
        playbackTime = time
        
        // Update stored pause position if seeking while paused
        // This ensures that if the user seeks while paused, the new position is remembered
        if !isPlaying {
            pausedAt = time
            print("📍 Manual seek while paused to: \(time)s")
        }
        
        // Update now playing info with new elapsed time
        updateNowPlayingInfoTime()
    }
    
    func loadWithoutPlaying(song: Song) {
        guard let url = getAudioURL(for: song) else {
            print("❌ No audio URL found for song: \(song.title)")
            return
        }
        
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

            // Reset failure counter on successful load
            consecutiveLoadFailures = 0
        } catch {
            print("❌ Failed to play audio: \(error)")
            print("❌ File may be corrupt or unsupported format")
            isPlaying = false

            // Track consecutive failures
            consecutiveLoadFailures += 1
            print("❌ Consecutive load failures: \(consecutiveLoadFailures)/\(maxConsecutiveFailures)")

            // Notify delegate to skip to next track (unless we've failed too many times)
            if consecutiveLoadFailures < maxConsecutiveFailures {
                print("🔄 Attempting to skip to next track...")
                delegate?.playbackDidFinish(successfully: false)
            } else {
                print("⚠️ Too many consecutive failures - stopping playback to prevent infinite loop")
                consecutiveLoadFailures = 0 // Reset for next attempt
            }
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

            // Reset failure counter on successful load
            consecutiveLoadFailures = 0
        } catch {
            print("❌ Failed to load audio: \(error)")
            print("❌ File may be corrupt or unsupported format")
            isPlaying = false

            // Track consecutive failures
            consecutiveLoadFailures += 1
            print("❌ Consecutive load failures: \(consecutiveLoadFailures)/\(maxConsecutiveFailures)")

            // Notify delegate to skip to next track (unless we've failed too many times)
            if consecutiveLoadFailures < maxConsecutiveFailures {
                print("🔄 Attempting to skip to next track...")
                delegate?.playbackDidFinish(successfully: false)
            } else {
                print("⚠️ Too many consecutive failures - stopping playback to prevent infinite loop")
                consecutiveLoadFailures = 0 // Reset for next attempt
            }
        }
    }
    
    private func commonLoadForResume(url: URL, resumeTime: TimeInterval) {
        // Special load method for resume that preserves pause position
        ensureAudioSessionConfigured()

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.volume = systemVolume // Apply current system volume

            songDuration = player?.duration ?? 0.0
            // Don't reset playbackTime to 0 - preserve the pause position
            playbackTime = resumeTime

            // Don't play, just load
            isPlaying = false
            stopTimer()

            // Reset failure counter on successful load
            consecutiveLoadFailures = 0
        } catch {
            print("❌ Failed to load audio for resume: \(error)")
            print("❌ File may be corrupt or unsupported format")
            isPlaying = false

            // Track consecutive failures
            consecutiveLoadFailures += 1
            print("❌ Consecutive load failures: \(consecutiveLoadFailures)/\(maxConsecutiveFailures)")

            // Notify delegate to skip to next track (unless we've failed too many times)
            if consecutiveLoadFailures < maxConsecutiveFailures {
                print("🔄 Attempting to skip to next track...")
                delegate?.playbackDidFinish(successfully: false)
            } else {
                print("⚠️ Too many consecutive failures - stopping playback to prevent infinite loop")
                consecutiveLoadFailures = 0 // Reset for next attempt
            }
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
        
        // Schedule cleanup after 30 seconds of being paused to save memory
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
        
        // CRITICAL: Notify AudioPlayerService to coordinate with QueueManager
        // This prevents the queue from being reloaded after memory cleanup
        AudioPlayerService.shared.notifyMemoryCleanup()
        
        print("🧹 Audio resources cleaned up - stored position \(pausedAt)s for song: \(lastPlayedSong?.title ?? "Unknown")")
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
        
        print("🔄 Resuming playback at \(time)s after memory cleanup for: \(song.title)")
        
        // Use a more reliable approach: load, prepare, seek, then play
        ensureAudioSessionConfigured()
        
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.volume = systemVolume
            
            // Prepare the player to ensure it's ready for operations
            let prepareSuccess = player?.prepareToPlay() ?? false
            print("🔧 AVAudioPlayer prepare result: \(prepareSuccess)")
            
            guard let player = player else {
                print("❌ Player is nil after creation")
                return
            }
            
            songDuration = player.duration
            
            // Seek BEFORE setting up for playback
            if time > 0 && time <= player.duration {
                player.currentTime = time
                playbackTime = time
                print("🎯 Seeked to \(time)s (duration: \(player.duration)s)")
            } else {
                playbackTime = 0
                print("⚠️ Invalid seek time \(time)s, duration is \(player.duration)s")
            }
            
            // Now start playing from the seek position
            player.play()
            isPlaying = true
            startTimer()
            
            updateNowPlayingInfo(for: song)
            
        } catch {
            print("❌ Failed to resume audio: \(error)")
            isPlaying = false
        }
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
        
        print("🎵 Setting up Now Playing info for: \(song.title) by \(song.artist) from \(song.releaseDate)")
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist.isEmpty ? "Unknown Artist" : song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album.isEmpty ? "Unknown Album" : song.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = max(0, songDuration)
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, playbackTime)
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        // CRITICAL FIX: Add artwork to Now Playing info
        if let artwork = getArtwork(for: song) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            print("✅ Added artwork to Now Playing info")
        } else {
            print("⚠️ No artwork available for Now Playing info")
        }
        
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            print("✅ Now Playing info updated with artwork and album info")
            print("📊 Now Playing Center state: \(MPNowPlayingInfoCenter.default().nowPlayingInfo != nil ? "Active" : "Inactive")")
        }
    }
    
    private func updateNowPlayingInfoTime() {
        // Update only time-sensitive properties without recreating the entire info
        guard var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            // If no info exists, we need to recreate it with artwork
            if let song = lastPlayedSong {
                print("🎵 Recreating Now Playing info with artwork during time update")
                updateNowPlayingInfo(for: song)
            }
            return
        }
        
        // Just update time properties, preserving artwork and all other metadata
        currentInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, playbackTime)
        currentInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
        }
    }
    
    // MARK: - Audio Session & Volume Management
    
    private func ensureAudioSessionConfigured() {
        guard !audioSessionConfigured else { return }
        
        let session = AVAudioSession.sharedInstance()
        print("🔊 Configuring audio session - Current Category: \(session.category.rawValue)")
        
        // First, ensure the session is properly deactivated if needed
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            print("🔄 Reset audio session state")
        } catch {
            print("ℹ️ Audio session reset not needed: \(error)")
        }
        
        // Small delay to ensure session state is stable
        Thread.sleep(forTimeInterval: 0.1)
        
        do {
            // Set category with options for Now Playing and Control Center support
            try session.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
            print("🔊 Audio session category set to .playback with mode .default and bluetooth options")
            
            // Activate the session
            try session.setActive(true)
            print("🔊 Audio session activated successfully")
            
            audioSessionConfigured = true
            print("✅ Audio session configured successfully - Now Playing should be available")
        } catch let error as NSError {
            print("❌ Failed to configure audio session: \(error) - Code: \(error.code)")
            
            // Try a simpler approach if the full setup fails
            do {
                // Try with just the playback category, no options
                try session.setCategory(.playback, mode: .default, policy: .default, options: [])
                print("🔊 Fallback: Audio session category set to .playback with default settings")
                try session.setActive(true)
                print("🔊 Fallback: Audio session activated successfully")
                audioSessionConfigured = true
                print("✅ Fallback audio session configured successfully - Now Playing should still work")
            } catch {
                print("❌ Even fallback audio session setup failed: \(error)")
                // Even if configuration fails, mark as configured to prevent infinite loops
                audioSessionConfigured = true
            }
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(handleRouteChange(notification:)), 
            name: AVAudioSession.routeChangeNotification, 
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(notification:)),
            name: AVAudioSession.interruptionNotification,
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
    
    @objc private func handleRouteChange(notification: Notification) {
        print("🔄 Audio route change detected")
        
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            print("⚠️ Could not determine route change reason")
            updateCurrentOutputName()
            updateSystemVolume()
            return
        }
        
        print("🔄 Route change reason: \(routeChangeReasonDescription(reason))")
        
        switch reason {
        case .oldDeviceUnavailable:
            print("🎧 Bluetooth device disconnected - handling disconnection")
            handleBluetoothDisconnection()
            
        case .newDeviceAvailable:
            print("🎧 New audio device connected - seamless handoff")
            updateCurrentOutputName()
            updateSystemVolume()
            // Continue playback seamlessly for new device connections
            
        default:
            print("🔄 Other route change - updating audio state")
            updateCurrentOutputName()
            updateSystemVolume()
        }
    }
    
    @objc private func handleVolumeChange() {
        updateSystemVolume()
    }
    
    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            print("⚠️ Could not determine interruption type")
            return
        }

        switch type {
        case .began:
            print("========================================")
            print("❌ AUDIO INTERRUPTION DETECTED")
            print("📞 Audio session interruption began")
            print("   Possible causes: phone call, alarm, notification, Siri, FaceTime")
            print("   Current track: \(lastPlayedSong?.title ?? "Unknown")")
            print("   Playback position: \(player?.currentTime ?? 0)s")
            print("========================================")
            if isPlaying {
                player?.pause()
                isPlaying = false
                stopTimer()
                updateNowPlayingInfoTime()
            }

        case .ended:
            print("========================================")
            print("✅ AUDIO INTERRUPTION ENDED")
            print("📞 Audio session interruption ended")

            // Check if we should resume playback
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("🔄 System suggests resuming playback after interruption")
                    print("   Note: App does NOT auto-resume - user must manually resume")
                    print("   This provides predictable behavior")
                }
            }
            print("========================================")

        @unknown default:
            print("❓ Unknown interruption type")
        }
    }
    
    private func handleBluetoothDisconnection() {
        print("🎧 Handling Bluetooth disconnection")
        
        // Always pause playback when Bluetooth disconnects
        if let player = player {
            if player.isPlaying {
                print("⏸️ Pausing playback due to Bluetooth disconnection")
                player.pause()
            }
            
            // Sync player state if inconsistent
            if player.isPlaying != isPlaying {
                print("🔧 Syncing player state - player.isPlaying: \(player.isPlaying), UI isPlaying: \(isPlaying)")
            }
        }
        
        // Update UI state
        isPlaying = false
        stopTimer()
        
        // Update Now Playing info to reflect paused state
        updateNowPlayingInfoTime()
        
        // Update output name and volume for the new route
        updateCurrentOutputName()
        updateSystemVolume()
        
        print("✅ Bluetooth disconnection handled - playback paused, UI updated")
    }
    
    private func routeChangeReasonDescription(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown:
            return "Unknown"
        case .newDeviceAvailable:
            return "New Device Available"
        case .oldDeviceUnavailable:
            return "Old Device Unavailable (Bluetooth Disconnected)"
        case .categoryChange:
            return "Category Change"
        case .override:
            return "Override"
        case .wakeFromSleep:
            return "Wake From Sleep"
        case .noSuitableRouteForCategory:
            return "No Suitable Route For Category"
        case .routeConfigurationChange:
            return "Route Configuration Change"
        @unknown default:
            return "Unknown Default"
        }
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
    
    // MARK: - Remote Command Center
    
    private func setupRemoteCommandCenter() {
        print("🎛️ Setting up Remote Command Center...")
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            print("▶️ Remote play command received")
            self.playPause()
            return .success
        }
        
        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            print("⏸️ Remote pause command received")
            self.playPause()
            return .success
        }
        
        // Toggle play/pause command (for headphones)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            print("⏯️ Remote toggle play/pause command received")
            self.playPause()
            return .success
        }
        
        // Next track command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            // Notify delegate to play next track
            self.delegate?.playbackDidFinish(successfully: true)
            return .success
        }
        
        // Previous track command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            // Check if we should restart current track or go to previous
            if let currentTime = self.player?.currentTime, currentTime > 4.0 {
                // If more than 3 seconds in, restart current track
                self.seek(to: 0)
            } else {
                // Otherwise, request previous track through AudioPlayerService
                NotificationCenter.default.post(name: Notification.Name("PlayPreviousTrack"), object: nil)
            }
            return .success
        }
        
        // Disable seek forward/backward commands to ensure track navigation buttons appear
        // These commands cause the 10-second seek buttons to appear instead of track navigation
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        
        // Change playback position command (for scrubber)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            
            self.seek(to: positionEvent.positionTime)
            return .success
        }
        
        print("✅ Remote Command Center configured")
        print("🎛️ Commands enabled: play, pause, toggle, next track, previous track, scrub")
    }
    
    // Force refresh Now Playing info (for debugging Control Center issues)
    func refreshNowPlayingInfo() {
        guard let currentSong = lastPlayedSong else {
            print("❌ No current song to refresh Now Playing info")
            return
        }
        print("🔄 Force refreshing Now Playing info...")
        updateNowPlayingInfo(for: currentSong)
    }
    
    private func teardownRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        // Skip commands are disabled, no need to remove targets
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        
        print("🧹 Remote Command Center cleaned up")
    }
    
    // MARK: - Notification Integration
    
    private func scheduleTrackChangeNotification(for song: Song, isManualSelection: Bool) {
        // Schedule the notification - let the notification service decide whether to send it
        NotificationService.shared.scheduleTrackChangeNotification(
            song: song,
            artwork: nil,
            isManualSelection: isManualSelection
        )
    }
    
    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("========================================")
        print("🎵 AVAudioPlayer finished playing")
        print("   Track: \(lastPlayedSong?.title ?? "Unknown")")
        print("   Successfully: \(flag ? "✅ YES" : "❌ NO")")
        print("   Duration: \(player.duration)s")
        print("   Final position: \(player.currentTime)s")
        if !flag {
            print("   ⚠️ WARNING: Track did not finish successfully!")
            print("   This indicates an audio error occurred")
        } else {
            // Reset failure counter on successful playback
            consecutiveLoadFailures = 0
        }
        print("========================================")

        isPlaying = false
        stopTimer()
        delegate?.playbackDidFinish(successfully: flag)
    }
}
