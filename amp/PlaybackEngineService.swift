import Foundation
import AVFoundation
import MediaPlayer
import UIKit

protocol PlaybackEngineDelegate: AnyObject {
    func playbackDidFinish(successfully: Bool)
    func playbackTimeDidUpdate(_ time: TimeInterval)
}

// AVAudioEngine + AVAudioPlayerNode playback core. Public API and
// PlaybackEngineDelegate preserve the AVAudioPlayer contract, so
// AudioPlayerService and the UI layer see the same shape.
//
// Time math: AVAudioEngine's playerNode reports "sample time since the
// most recent .play()" via `playerTime(forNodeTime:)`. We track the
// offset in seconds at which the currently-scheduled segment starts
// (`segmentStartOffset`) and add the node's elapsed time to get wall-
// clock position in the track. Pause/resume without a new schedule
// keeps sampleTime accumulating; seek requires stop()+scheduleSegment()
// which resets sampleTime to 0, so we reset segmentStartOffset at the
// same time.

class PlaybackEngineService: NSObject, ObservableObject {
    // MARK: - Public surface

    weak var delegate: PlaybackEngineDelegate?

    @Published var isPlaying = false
    @Published var songDuration: TimeInterval = 0.0
    @Published var playbackTime: TimeInterval = 0.0
    @Published var currentOutputName: String = ""
    @Published var isBluetoothRouteActive: Bool = false
    @Published var isWiredRouteActive: Bool = false
    @Published var systemVolume: Float = 1.0

    var hasAudioReady: Bool {
        return file != nil
    }

    // MARK: - Audio graph state

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var file: AVAudioFile?

    // Seconds into the track at which the currently-scheduled segment
    // starts. Add to playerNode's elapsed sampleTime to get wall-clock
    // position.
    private var segmentStartOffset: TimeInterval = 0

    // Uniquely identifies the most recent scheduleSegment call so stale
    // completion callbacks (from segments that got stop()'d on seek) can
    // be filtered out.
    private var currentScheduleToken = UUID()

    // MARK: - Other state (carried over verbatim from the AVAudioPlayer version)

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

    override init() {
        super.init()

        setupAudioGraph()

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
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - Audio graph

    private func setupAudioGraph() {
        engine.attach(playerNode)
        // Connect with nil format so the mixer picks up the player's
        // eventual output format. scheduleSegment will supply the file's
        // processingFormat when we actually play something; the mixer
        // adapts automatically.
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
            print("🎛️ AVAudioEngine started")
        } catch {
            print("❌ Failed to start AVAudioEngine: \(error)")
        }
    }

    // Time in the track right now, in seconds. Offset + node elapsed.
    // If the node hasn't rendered yet (just scheduled, not playing),
    // falls back to the offset so UI shows the expected position.
    private func currentPlaybackTime() -> TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return segmentStartOffset
        }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        return segmentStartOffset + max(0, elapsed)
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

        // For a same-song resume, start the segment at the stored pause
        // position (or the user's manual seek position if that differs).
        let startSeconds: TimeInterval
        if isSameSong {
            let hasManuallySeeked = abs(playbackTime - storedPausePosition) > 0.1
            startSeconds = hasManuallySeeked ? playbackTime : storedPausePosition
            if hasManuallySeeked {
                print("✅ Resuming from manual seek position: \(startSeconds)s")
            } else {
                print("✅ Resuming from stored pause position: \(startSeconds)s")
            }
        } else {
            startSeconds = 0
        }

        schedulePlayback(url: url, fromSeconds: startSeconds, autoPlay: true)

        updateNowPlayingInfo(for: song)

        // Schedule notification for track change
        scheduleTrackChangeNotification(for: song, isManualSelection: isManualSelection)
    }

    func playPause() {
        if playerNode.isPlaying {
            // Currently playing — pause.
            pausedAt = currentPlaybackTime()
            print("⏸️ Pausing at position: \(pausedAt)s")

            playerNode.pause()
            isPlaying = false
            stopTimer()
            updateNowPlayingInfoTime()
            scheduleDelayedCleanup()
        } else if file != nil {
            // Node is paused OR stopped-with-a-pending-segment (from a
            // seek-while-paused). Either way, play() resumes.
            isResumingFromPause = true

            let hasManuallySeeked = abs(playbackTime - pausedAt) > 0.1
            let resumePosition = hasManuallySeeked ? playbackTime : pausedAt

            if resumePosition > 0 && abs(resumePosition - currentPlaybackTime()) > 0.1 {
                // Segment was scheduled from a different position; reschedule
                // to land exactly on resumePosition.
                if let url = lastPlayedSong.flatMap({ getAudioURL(for: $0) }) {
                    schedulePlayback(url: url, fromSeconds: resumePosition, autoPlay: true)
                    isResumingFromPause = false
                    return
                }
            }

            if hasManuallySeeked {
                print("▶️ Resuming from manual seek position: \(resumePosition)s")
            } else {
                print("▶️ Resuming from current node position")
            }

            ensureEngineRunning()
            playerNode.play()
            isPlaying = true
            startTimer()
            cancelDelayedCleanup()
            updateNowPlayingInfoTime()
            isResumingFromPause = false
        } else if let song = lastPlayedSong {
            // File was released (30s cleanup). Reload and resume.
            print("🔄 Entering resume path - song: \(song.title), pausedAt: \(pausedAt)s")
            isResumingFromPause = true
            resumeFromPause(song: song, at: pausedAt)
            isResumingFromPause = false
        } else {
            print("⚠️ PlayPause called but no audio is loaded. Use play(song:) to start playback.")
        }
    }

    func stop() {
        playerNode.stop()
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
        // If we have a file loaded, reschedule from the new frame. If we
        // don't (post-cleanup), just remember pausedAt — the next resume
        // will reopen at this position.
        if let audioFile = file {
            let wasPlaying = playerNode.isPlaying
            let sampleRate = audioFile.processingFormat.sampleRate
            let clampedTime = max(0, min(songDuration, time))
            let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
            let framesRemaining = AVAudioFrameCount(max(0, audioFile.length - startFrame))

            playerNode.stop()

            if framesRemaining > 0 {
                segmentStartOffset = clampedTime
                playbackTime = clampedTime
                let myToken = UUID()
                currentScheduleToken = myToken

                playerNode.scheduleSegment(
                    audioFile,
                    startingFrame: startFrame,
                    frameCount: framesRemaining,
                    at: nil,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    self?.handleScheduleCompletion(token: myToken)
                }

                if wasPlaying {
                    ensureEngineRunning()
                    playerNode.play()
                }
            } else {
                // Seek past end of track — treat as completion.
                segmentStartOffset = clampedTime
                playbackTime = clampedTime
            }
        } else {
            playbackTime = time
        }

        // Update stored pause position if seeking while paused so the next
        // resume lands here.
        if !isPlaying {
            pausedAt = playbackTime
            print("📍 Manual seek while paused to: \(playbackTime)s")
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

        schedulePlayback(url: url, fromSeconds: 0, autoPlay: false)
        updateNowPlayingInfo(for: song)
    }

    // Cold-launch fast path. Opens AVAudioFile directly with a pre-known
    // URL (from CurrentTrackSnapshot), bypassing the MPMediaQuery that
    // loadWithoutPlaying does. Returns false if the file open fails — the
    // caller uses that signal to skip applying the snapshot to the queue
    // manager, letting the normal restore path handle it.
    //
    // Only intended to be called once at init, before any playback state
    // exists. Post-init code paths should go through play() / loadWithoutPlaying().
    @discardableResult
    func loadWithURL(song: Song, url: URL, seekTo: TimeInterval = 0) -> Bool {
        ensureAudioSessionConfigured()
        ensureEngineRunning()

        do {
            let audioFile = try AVAudioFile(forReading: url)
            file = audioFile

            let sampleRate = audioFile.processingFormat.sampleRate
            let totalFrames = audioFile.length
            songDuration = Double(totalFrames) / sampleRate

            let clampedStart = max(0, min(songDuration, seekTo))
            let startFrame = AVAudioFramePosition(clampedStart * sampleRate)
            let framesRemaining = AVAudioFrameCount(max(0, totalFrames - startFrame))

            guard framesRemaining > 0 else {
                print("⚡ Eager load: requested seek past end of track — discarding")
                file = nil
                return false
            }

            playerNode.stop()
            segmentStartOffset = clampedStart
            playbackTime = clampedStart
            pausedAt = clampedStart

            let myToken = UUID()
            currentScheduleToken = myToken

            playerNode.scheduleSegment(
                audioFile,
                startingFrame: startFrame,
                frameCount: framesRemaining,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.handleScheduleCompletion(token: myToken)
            }

            isPlaying = false
            lastPlayedSong = song
            updateNowPlayingInfo(for: song)
            print(String(format: "⚡ Eager load: ready — %@ at %.3fs", song.title, clampedStart))
            return true
        } catch {
            // Stale URL (track deleted from library) or other open failure.
            // Don't propagate an error state — caller falls through to the
            // normal queue-restore path.
            print("⚡ Eager load: AVAudioFile open failed for \(song.title) — \(error). Falling through.")
            return false
        }
    }

    // MARK: - Scheduling

    // Central scheduling routine. Opens the file (if URL differs or no
    // file loaded), stops any previously-scheduled segment, sets the
    // seconds-offset for time math, and optionally kicks off playback.
    private func schedulePlayback(url: URL, fromSeconds: TimeInterval, autoPlay: Bool) {
        ensureAudioSessionConfigured()
        ensureEngineRunning()

        do {
            let audioFile = try AVAudioFile(forReading: url)
            file = audioFile

            let sampleRate = audioFile.processingFormat.sampleRate
            let totalFrames = audioFile.length
            songDuration = Double(totalFrames) / sampleRate

            let clampedStart = max(0, min(songDuration, fromSeconds))
            let startFrame = AVAudioFramePosition(clampedStart * sampleRate)
            let framesRemaining = AVAudioFrameCount(max(0, totalFrames - startFrame))

            guard framesRemaining > 0 else {
                print("⚠️ Scheduled past end of track — treating as completion")
                isPlaying = false
                delegate?.playbackDidFinish(successfully: true)
                return
            }

            playerNode.stop()

            segmentStartOffset = clampedStart
            playbackTime = clampedStart

            let myToken = UUID()
            currentScheduleToken = myToken

            playerNode.scheduleSegment(
                audioFile,
                startingFrame: startFrame,
                frameCount: framesRemaining,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.handleScheduleCompletion(token: myToken)
            }

            if autoPlay {
                playerNode.play()
                isPlaying = true
                startTimer()
            } else {
                isPlaying = false
                stopTimer()
            }

            consecutiveLoadFailures = 0
        } catch {
            print("❌ Failed to open audio file: \(error)")
            print("❌ File may be corrupt or unsupported format")
            isPlaying = false

            consecutiveLoadFailures += 1
            print("❌ Consecutive load failures: \(consecutiveLoadFailures)/\(maxConsecutiveFailures)")

            if consecutiveLoadFailures < maxConsecutiveFailures {
                print("🔄 Attempting to skip to next track...")
                delegate?.playbackDidFinish(successfully: false)
            } else {
                print("⚠️ Too many consecutive failures - stopping playback to prevent infinite loop")
                consecutiveLoadFailures = 0
            }
        }
    }

    // Completion handler for scheduleSegment. Fires on a background queue
    // and can arrive *after* a manual stop/seek has discarded the segment
    // (AVFoundation drains pending callbacks); gate on the token + current
    // file state to suppress stale fires.
    private func handleScheduleCompletion(token: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.currentScheduleToken == token else {
                print("🗑️ Stale scheduleSegment completion (token mismatch) — ignoring")
                return
            }
            guard self.file != nil else {
                print("🗑️ scheduleSegment completion after stop — ignoring")
                return
            }
            print("========================================")
            print("🎵 AVAudioPlayerNode finished playing segment")
            print("   Track: \(self.lastPlayedSong?.title ?? "Unknown")")
            print("========================================")
            self.consecutiveLoadFailures = 0
            self.isPlaying = false
            self.stopTimer()
            self.delegate?.playbackDidFinish(successfully: true)
        }
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

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = self.currentPlaybackTime()
            self.playbackTime = now
            self.delegate?.playbackTimeDidUpdate(now)

            // Update now playing info every second to avoid excessive updates
            if now - self.lastNowPlayingUpdate >= 1.0 {
                self.updateNowPlayingInfoTime()
                self.lastNowPlayingUpdate = now
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
        // Release the file handle but keep the engine graph intact.
        // Engine idle overhead is ~1–2MB; full restart is more expensive
        // than staying warm. On resume we reopen the file at pausedAt.
        guard file != nil else { return }

        // pausedAt was already captured when pause fired, but re-capture
        // in case something slipped through.
        pausedAt = currentPlaybackTime() > 0 ? currentPlaybackTime() : pausedAt

        playerNode.stop()
        file = nil
        playbackTime = pausedAt

        deactivateAudioSessionIfNeeded()

        // CRITICAL: Notify AudioPlayerService to coordinate with QueueManager
        // This prevents the queue from being reloaded after memory cleanup
        AudioPlayerService.shared.notifyMemoryCleanup()

        print("🧹 Audio resources cleaned up - stored position \(pausedAt)s for song: \(lastPlayedSong?.title ?? "Unknown")")
    }

    private func cleanupAudioResourcesOnStop() {
        playerNode.stop()
        file = nil
        lastPlayedSong = nil
        pausedAt = 0
        songDuration = 0.0
        playbackTime = 0.0
        segmentStartOffset = 0
        deactivateAudioSessionIfNeeded()
    }

    private func resumeFromPause(song: Song, at time: TimeInterval) {
        // File was released by the 30s cleanup timer. Reopen and schedule
        // from `time`, then play.
        guard let url = getAudioURL(for: song) else {
            print("❌ Cannot resume - no audio URL found for song: \(song.title)")
            return
        }

        print("🔄 Resuming playback at \(time)s after memory cleanup for: \(song.title)")

        schedulePlayback(url: url, fromSeconds: time, autoPlay: true)
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
        guard !audioSessionConfigured else {
            // Session already up; just make sure the engine is running.
            ensureEngineRunning()
            return
        }

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

            // With the session active, start the engine (idempotent).
            ensureEngineRunning()
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
                ensureEngineRunning()
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
            engine.mainMixerNode.outputVolume = systemVolume
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
            print("   Playback position: \(currentPlaybackTime())s")
            print("========================================")
            if isPlaying {
                pausedAt = currentPlaybackTime()
                playerNode.pause()
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
            // The engine may need restarting after the session deactivation
            // the system performed. Next playPause() will re-prep via
            // ensureAudioSessionConfigured → ensureEngineRunning.
            print("========================================")

        @unknown default:
            print("❓ Unknown interruption type")
        }
    }

    private func handleBluetoothDisconnection() {
        print("🎧 Handling old-device-unavailable route change")

        // If another output is still available (e.g. a Lightning cable was
        // plugged in while BT was active), iOS has already routed audio to
        // it. Don't pause — that would give the user a jarring stop instead
        // of a seamless handoff. Only pause when no output remains, which
        // is the "BT walked away" / headphones-unplugged-to-silence case.
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if !outputs.isEmpty && isPlaying {
            print("🎧 \(outputs.count) output(s) remain — continuing seamlessly on new route")
            ensureEngineRunning()
            // iOS may have paused the node internally while swapping routes;
            // re-issue play() so sample rendering resumes on the new device.
            if !playerNode.isPlaying {
                playerNode.play()
            }
            updateCurrentOutputName()
            updateSystemVolume()
            return
        }

        // No remaining output — pause as before.
        if playerNode.isPlaying {
            print("⏸️ Pausing playback — no output route remains")
            pausedAt = currentPlaybackTime()
            playerNode.pause()
        }

        if playerNode.isPlaying != isPlaying {
            print("🔧 Syncing player state - node.isPlaying: \(playerNode.isPlaying), UI isPlaying: \(isPlaying)")
        }

        isPlaying = false
        stopTimer()
        updateNowPlayingInfoTime()
        updateCurrentOutputName()
        updateSystemVolume()

        print("✅ Route change handled - playback paused, UI updated")
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

        // Apply system volume to engine output to handle Bluetooth floor issue
        engine.mainMixerNode.outputVolume = systemVolume

        print("🎵 Engine mixer volume set to: \(engine.mainMixerNode.outputVolume)")
    }

    private func updateCurrentOutputName() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        if let first = outputs.first {
            currentOutputName = first.portName
        } else {
            currentOutputName = "iPhone"
        }
        let btPortTypes: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        isBluetoothRouteActive = outputs.contains { btPortTypes.contains($0.portType) }
        // iOS reports Lightning and 3.5mm headphones identically as
        // .headphones — we can't distinguish the two. .usbAudio covers
        // some Lightning/USB-C audio interfaces.
        let wiredPortTypes: Set<AVAudioSession.Port> = [.headphones, .headsetMic, .usbAudio]
        isWiredRouteActive = outputs.contains { wiredPortTypes.contains($0.portType) }
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
            if self.currentPlaybackTime() > 4.0 {
                // If more than 4 seconds in, restart current track
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
}
