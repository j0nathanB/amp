import Foundation
import AVFoundation
import MediaPlayer
import UIKit

protocol PlaybackEngineDelegate: AnyObject {
    func playbackDidFinish(successfully: Bool)
    func playbackTimeDidUpdate(_ time: TimeInterval)
}

// AVAudioPlayer-based playback core. Reverted from AVAudioEngine on
// 2026-04-26: AVAudioFile(forReading:) can't open `ipod-library://`
// URLs that MPMediaItem.assetURL returns for tracks added through the
// iOS Music app, which made some local tracks fail at file-open. The
// engine path was originally added to support per-band equalizer
// envelopes; that feature was dropped (commit 5af1405), so AVAudioEngine
// is no longer load-bearing.

class PlaybackEngineService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    // MARK: - Public surface

    weak var delegate: PlaybackEngineDelegate?

    @Published var isPlaying = false
    @Published var songDuration: TimeInterval = 0.0
    @Published var playbackTime: TimeInterval = 0.0
    @Published var currentOutputName: String = ""
    @Published var isBluetoothRouteActive: Bool = false
    @Published var isWiredRouteActive: Bool = false
    @Published var systemVolume: Float = 1.0

    // MARK: - Playback state

    private var player: AVAudioPlayer?

    // MARK: - Other state

    private var timer: Timer?
    private var volumeView: MPVolumeView?
    private var volumeObserver: NSKeyValueObservation?
    private var audioSessionConfigured = false
    private var lastPlayedSong: Song?
    private var pausedAt: TimeInterval = 0
    private var lastNowPlayingUpdate: TimeInterval = 0
    private var pauseCleanupTimer: Timer?

    // Track consecutive load failures to prevent infinite skip loops
    private var consecutiveLoadFailures = 0
    private let maxConsecutiveFailures = 5

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
            // Match the AVAudioPlayer-throw path's state (lastPlayedSong /
            // pausedAt set before the failure) and route through the same
            // recovery. The old early-return left the PREVIOUS track's
            // player loaded while currentTrack showed the new song —
            // play/pause then resumed the wrong audio — and never entered
            // the skip cascade, so playback just dead-stopped.
            lastPlayedSong = song
            pausedAt = 0
            handleLoadFailure(error: PlaybackLoadError.noAssetURL, song: song)
            return
        }

        // Check if this is the same song being resumed
        let isSameSong = lastPlayedSong?.persistentID == song.persistentID
        let storedPausePosition = pausedAt

        // Track the song for memory management
        lastPlayedSong = song

        // Only reset pausedAt if this is a genuinely new song
        if !isSameSong {
            pausedAt = 0
            print("🎵 Playing new song: \(song.title)")
        } else {
            print("🎵 Resuming same song: \(song.title) from position \(storedPausePosition)s")
        }

        // Cancel any pending cleanup since we're starting new playback
        cancelDelayedCleanup()

        // For a same-song resume, start at the stored pause position (or
        // user's manual seek position if that differs).
        let startSeconds: TimeInterval
        if isSameSong {
            let hasManuallySeeked = abs(playbackTime - storedPausePosition) > 0.1
            startSeconds = hasManuallySeeked ? playbackTime : storedPausePosition
        } else {
            startSeconds = 0
        }

        ensureAudioSessionConfigured()

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.volume = systemVolume
            newPlayer.prepareToPlay()
            songDuration = newPlayer.duration

            let clampedStart = max(0, min(songDuration, startSeconds))
            newPlayer.currentTime = clampedStart
            playbackTime = clampedStart

            player = newPlayer
            newPlayer.play()
            isPlaying = true
            startTimer()

            consecutiveLoadFailures = 0

            updateNowPlayingInfo(for: song)
            scheduleTrackChangeNotification(for: song, isManualSelection: isManualSelection)
        } catch {
            handleLoadFailure(error: error, song: song)
        }
    }

    func playPause() {
        if let player = player, player.isPlaying {
            // Currently playing — pause. AVAudioPlayer preserves position.
            pausedAt = player.currentTime
            print("⏸️ Pausing at position: \(pausedAt)s")

            player.pause()
            isPlaying = false
            stopTimer()
            updateNowPlayingInfoTime()
            scheduleDelayedCleanup()
        } else if let player = player {
            // Player exists but is paused — resume.
            ensureAudioSessionConfigured()
            player.volume = systemVolume
            player.play()
            isPlaying = true
            startTimer()
            cancelDelayedCleanup()
            updateNowPlayingInfoTime()
        } else if let song = lastPlayedSong {
            // Player was released by the 30s cleanup. Reload and resume.
            print("🔄 Reloading after cleanup — song: \(song.title), pausedAt: \(pausedAt)s")
            resumeFromPause(song: song, at: pausedAt)
        } else {
            print("⚠️ PlayPause called but no audio is loaded. Use play(song:) to start playback.")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        playbackTime = 0.0
        stopTimer()
        cleanupAudioResourcesOnStop()
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            print("🧹 Cleared Now Playing info after stop")
        }
    }

    func seek(to time: TimeInterval) {
        let clampedTime = max(0, min(songDuration, time))

        if let player = player {
            player.currentTime = clampedTime
            playbackTime = clampedTime
        } else {
            // No player loaded (post-cleanup). Remember position for next resume.
            playbackTime = clampedTime
        }

        // If seeking while paused, update pausedAt so the next resume lands here.
        if !isPlaying {
            pausedAt = playbackTime
            print("📍 Manual seek while paused to: \(playbackTime)s")
        }

        // Push the new position to QueueManager immediately. While paused
        // the playback timer isn't running, so without this a seek-then-kill
        // persists the pre-seek position.
        delegate?.playbackTimeDidUpdate(playbackTime)

        updateNowPlayingInfoTime()
    }

    func loadWithoutPlaying(song: Song) {
        guard let url = getAudioURL(for: song) else {
            print("❌ No audio URL found for song: \(song.title)")
            // Same rationale as play(): clear stale player state and enter
            // the capped failure cascade instead of dead-ending.
            lastPlayedSong = song
            pausedAt = 0
            handleLoadFailure(error: PlaybackLoadError.noAssetURL, song: song)
            return
        }

        lastPlayedSong = song
        pausedAt = 0

        ensureAudioSessionConfigured()

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.volume = systemVolume
            newPlayer.prepareToPlay()
            songDuration = newPlayer.duration
            playbackTime = 0
            player = newPlayer
            isPlaying = false
            stopTimer()
            consecutiveLoadFailures = 0

            updateNowPlayingInfo(for: song)
        } catch {
            handleLoadFailure(error: error, song: song)
        }
    }

    // Cold-launch fast path. Initializes AVAudioPlayer directly with a
    // pre-known URL (from CurrentTrackSnapshot), bypassing the MPMediaQuery
    // round-trip that loadWithoutPlaying does. Returns false if the open
    // fails — the caller uses that signal to skip applying the snapshot
    // to the queue manager, letting the normal restore path handle it.
    //
    // Only intended to be called once at init, before any playback state
    // exists. Post-init code paths should go through play() / loadWithoutPlaying().
    @discardableResult
    func loadWithURL(song: Song, url: URL, seekTo: TimeInterval = 0) -> Bool {
        ensureAudioSessionConfigured()

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.volume = systemVolume
            newPlayer.prepareToPlay()
            songDuration = newPlayer.duration

            let clampedStart = max(0, min(songDuration, seekTo))
            newPlayer.currentTime = clampedStart
            playbackTime = clampedStart
            pausedAt = clampedStart

            player = newPlayer
            isPlaying = false
            lastPlayedSong = song

            updateNowPlayingInfo(for: song)
            print(String(format: "⚡ Eager load: ready — %@ at %.3fs", song.title, clampedStart))
            return true
        } catch {
            // Stale URL (track deleted from library) or other open failure.
            // Don't propagate via the failure cascade — caller falls through
            // to the normal queue-restore path.
            print("⚡ Eager load: AVAudioPlayer open failed for \(song.title) — \(error). Falling through.")
            return false
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Ignore stale callbacks from a player we've replaced.
        guard player === self.player else {
            print("🗑️ Stale audioPlayerDidFinishPlaying — ignoring")
            return
        }

        if flag {
            print("========================================")
            print("🎵 Track finished — \(lastPlayedSong?.title ?? "Unknown")")
            print("========================================")
            consecutiveLoadFailures = 0
        } else {
            print("⚠️ Track finished unsuccessfully — \(lastPlayedSong?.title ?? "Unknown")")
        }

        isPlaying = false
        stopTimer()
        delegate?.playbackDidFinish(successfully: flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        print("❌ Decode error during playback: \(error?.localizedDescription ?? "unknown")")
        isPlaying = false
        stopTimer()
        delegate?.playbackDidFinish(successfully: false)
    }

    // MARK: - Load failure plumbing

    // A track whose MPMediaItem has no assetURL (cloud-only item that isn't
    // downloaded, DRM, or removed from the library since the queue was
    // built). Routed through handleLoadFailure so it behaves exactly like
    // an AVAudioPlayer open failure.
    private enum PlaybackLoadError: LocalizedError {
        case noAssetURL
        var errorDescription: String? {
            "No asset URL for track (cloud-only, DRM, or removed from library)"
        }
    }

    // Shared catch handling for play() / loadWithoutPlaying(). loadWithURL
    // has its own explicit fall-through behavior and intentionally does
    // not route through here.
    private func handleLoadFailure(error: Error, song: Song) {
        print("❌ AVAudioPlayer init failed: \(error)")
        print("❌ File may be corrupt or unsupported format")
        logMediaItemDiagnostics(for: song)
        player = nil
        isPlaying = false

        consecutiveLoadFailures += 1
        print("❌ Consecutive load failures: \(consecutiveLoadFailures)/\(maxConsecutiveFailures)")

        if consecutiveLoadFailures < maxConsecutiveFailures {
            print("🔄 Attempting to skip past failed track…")
            delegate?.playbackDidFinish(successfully: false)
        } else {
            print("⚠️ Too many consecutive failures — stopping playback to break the loop")
            consecutiveLoadFailures = 0
        }
    }

    // Diagnostic dump of MPMediaItem properties for a track that failed
    // to open. Distinguishes DRM-protected items (hasProtectedAsset) from
    // cloud-only items (isCloudItem) from genuinely corrupt files.
    private func logMediaItemDiagnostics(for song: Song) {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: song.persistentID),
            forProperty: MPMediaItemPropertyPersistentID
        )
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)

        guard let item = query.items?.first else {
            print("🔬 [diag] No MPMediaItem found for failing track: \(song.title) (persistentID: \(song.persistentID))")
            return
        }

        let assetURL = item.assetURL?.absoluteString ?? "<nil>"
        let storeID = item.playbackStoreID

        print("🔬 [diag] Failing track diagnostics for: \(song.title)")
        print("🔬 [diag]   persistentID:       \(song.persistentID)")
        print("🔬 [diag]   hasProtectedAsset:  \(item.hasProtectedAsset)")
        print("🔬 [diag]   isCloudItem:        \(item.isCloudItem)")
        print("🔬 [diag]   playbackStoreID:    '\(storeID)'")
        print("🔬 [diag]   assetURL:           \(assetURL)")
        print("🔬 [diag]   mediaType.rawValue: \(item.mediaType.rawValue)")
        print("🔬 [diag]   albumTitle:         '\(item.albumTitle ?? "<nil>")'")
        print("🔬 [diag]   artist:             '\(item.artist ?? "<nil>")'")
    }

    // MARK: - Helpers

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
            let now = self.player?.currentTime ?? self.pausedAt
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
        pauseCleanupTimer?.invalidate()
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
        guard player != nil else { return }

        // pausedAt was already captured when pause fired, but re-capture
        // in case something slipped through.
        if let p = player, p.currentTime > 0 {
            pausedAt = p.currentTime
        }

        player?.stop()
        player = nil
        playbackTime = pausedAt

        deactivateAudioSessionIfNeeded()

        // Notify AudioPlayerService to coordinate with QueueManager —
        // prevents the queue from being reloaded after memory cleanup.
        AudioPlayerService.shared.notifyMemoryCleanup()

        print("🧹 Audio resources cleaned up — stored position \(pausedAt)s for song: \(lastPlayedSong?.title ?? "Unknown")")
    }

    private func cleanupAudioResourcesOnStop() {
        player?.stop()
        player = nil
        lastPlayedSong = nil
        pausedAt = 0
        songDuration = 0.0
        playbackTime = 0.0
        deactivateAudioSessionIfNeeded()
    }

    private func resumeFromPause(song: Song, at time: TimeInterval) {
        // Player was released by the 30s cleanup timer. Reopen and resume.
        guard let url = getAudioURL(for: song) else {
            print("❌ Cannot resume — no audio URL found for song: \(song.title)")
            return
        }

        print("🔄 Resuming playback at \(time)s after memory cleanup for: \(song.title)")

        ensureAudioSessionConfigured()

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.volume = systemVolume
            newPlayer.prepareToPlay()
            songDuration = newPlayer.duration

            let clampedStart = max(0, min(songDuration, time))
            newPlayer.currentTime = clampedStart
            playbackTime = clampedStart

            player = newPlayer
            newPlayer.play()
            isPlaying = true
            startTimer()
            consecutiveLoadFailures = 0

            updateNowPlayingInfo(for: song)
        } catch {
            handleLoadFailure(error: error, song: song)
        }
    }

    private func deactivateAudioSessionIfNeeded() {
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
            print("⚠️ Skipping now playing info update — empty song title")
            return
        }

        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist.isEmpty ? "Unknown Artist" : song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album.isEmpty ? "Unknown Album" : song.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = max(0, songDuration)
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, playbackTime)
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let artwork = getArtwork(for: song) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }

    private func updateNowPlayingInfoTime() {
        // Update only time-sensitive properties, preserving artwork etc.
        guard var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            // No info exists — recreate it with artwork.
            if let song = lastPlayedSong {
                updateNowPlayingInfo(for: song)
            }
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

        let session = AVAudioSession.sharedInstance()
        print("🔊 Configuring audio session — Current Category: \(session.category.rawValue)")

        // Reset session state if needed.
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            print("🔄 Reset audio session state")
        } catch {
            print("ℹ️ Audio session reset not needed: \(error)")
        }

        do {
            try session.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
            audioSessionConfigured = true
            print("✅ Audio session configured successfully")
        } catch let error as NSError {
            print("❌ Failed to configure audio session: \(error) — Code: \(error.code)")

            // Fallback with fewer options.
            do {
                try session.setCategory(.playback, mode: .default, policy: .default, options: [])
                try session.setActive(true)
                audioSessionConfigured = true
                print("✅ Fallback audio session configured")
            } catch {
                print("❌ Even fallback audio session setup failed: \(error)")
                // Mark as configured to prevent infinite loops.
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

        setupVolumeMonitoring()
        setupKVOVolumeMonitoring()
    }

    private func setupVolumeMonitoring() {
        // Hidden MPVolumeView to monitor system volume.
        volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 0, height: 0))
        volumeView?.isHidden = true
        volumeView?.alpha = 0.0

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.addSubview(volumeView!)
        }

        if let volumeSlider = volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider {
            volumeSlider.addTarget(self, action: #selector(handleVolumeChange), for: .valueChanged)
            systemVolume = volumeSlider.value
            player?.volume = systemVolume
        }
    }

    private func setupKVOVolumeMonitoring() {
        let audioSession = AVAudioSession.sharedInstance()
        volumeObserver = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
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
            handleBluetoothDisconnection()

        case .newDeviceAvailable:
            updateCurrentOutputName()
            updateSystemVolume()
            // AVAudioPlayer continues seamlessly across route additions.

        default:
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
            print("❌ Audio session interruption began (call/alarm/Siri/FaceTime/etc.)")
            print("   Current track: \(lastPlayedSong?.title ?? "Unknown")")
            if isPlaying, let player = player {
                pausedAt = player.currentTime
                player.pause()
                isPlaying = false
                stopTimer()
                // Timer is stopped — sync the final position to QueueManager
                // so a kill during the interruption persists it.
                delegate?.playbackTimeDidUpdate(pausedAt)
                updateNowPlayingInfoTime()
            }

        case .ended:
            print("✅ Audio session interruption ended")
            // Don't auto-resume — let the user explicitly resume. More
            // predictable than guessing whether resumption is wanted.
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("🔄 System suggests resume; app waits for explicit user action")
                }
            }

        @unknown default:
            print("❓ Unknown interruption type")
        }
    }

    private func handleBluetoothDisconnection() {
        // If another output is still available (e.g. a Lightning cable was
        // plugged in while BT was active), iOS has already routed audio to
        // it. Don't pause — that would give the user a jarring stop instead
        // of a seamless handoff. Only pause when no output remains, which
        // is the "BT walked away" / headphones-unplugged-to-silence case.
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if !outputs.isEmpty && isPlaying {
            print("🎧 \(outputs.count) output(s) remain — continuing seamlessly on new route")
            updateCurrentOutputName()
            updateSystemVolume()
            return
        }

        // No remaining output — pause.
        if let player = player, player.isPlaying {
            print("⏸️ Pausing playback — no output route remains")
            pausedAt = player.currentTime
            player.pause()
            // Same rationale as the interruption path: timer stops below,
            // sync the final position to QueueManager.
            delegate?.playbackTimeDidUpdate(pausedAt)
        }

        isPlaying = false
        stopTimer()
        updateNowPlayingInfoTime()
        updateCurrentOutputName()
        updateSystemVolume()
    }

    private func routeChangeReasonDescription(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "Unknown"
        case .newDeviceAvailable: return "New Device Available"
        case .oldDeviceUnavailable: return "Old Device Unavailable (Bluetooth Disconnected)"
        case .categoryChange: return "Category Change"
        case .override: return "Override"
        case .wakeFromSleep: return "Wake From Sleep"
        case .noSuitableRouteForCategory: return "No Suitable Route For Category"
        case .routeConfigurationChange: return "Route Configuration Change"
        @unknown default: return "Unknown Default"
        }
    }

    private func updateSystemVolume() {
        if let volumeSlider = volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider {
            systemVolume = volumeSlider.value
        } else {
            systemVolume = AVAudioSession.sharedInstance().outputVolume
        }

        // Apply system volume to the active player to handle the Bluetooth
        // floor issue (some BT routes attenuate AVAudioPlayer's default
        // 1.0 output and need explicit volume tracking).
        player?.volume = systemVolume
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
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.playPause()
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.playPause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.playPause()
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { _ in
            // Explicit advance via AudioPlayerService.nextTrack() (mirrors
            // the PlayPreviousTrack pattern below). The old implementation
            // impersonated track completion (playbackDidFinish(true)), which
            // runs the isLoopingSong check first — so lock-screen "next"
            // REPLAYED the current song whenever song-loop was on. Side
            // effect of the new route: remote next preserves play/pause
            // state instead of force-playing, matching Apple Music.
            NotificationCenter.default.post(name: Notification.Name("PlayNextTrack"), object: nil)
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            // >4s into track: restart current. Otherwise: post notification
            // that AudioPlayerService listens for to call its previousTrack().
            if (self.player?.currentTime ?? 0) > 4.0 {
                self.seek(to: 0)
            } else {
                NotificationCenter.default.post(name: Notification.Name("PlayPreviousTrack"), object: nil)
            }
            return .success
        }

        // Disable seek forward/backward so the lock-screen shows track-nav
        // buttons rather than 10-second skip buttons.
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: positionEvent.positionTime)
            return .success
        }
    }

    // Force refresh Now Playing info (for debugging Control Center issues)
    func refreshNowPlayingInfo() {
        guard let currentSong = lastPlayedSong else {
            print("❌ No current song to refresh Now Playing info")
            return
        }
        updateNowPlayingInfo(for: currentSong)
    }

    private func teardownRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
    }

    // MARK: - Notification Integration

    private func scheduleTrackChangeNotification(for song: Song, isManualSelection: Bool) {
        NotificationService.shared.scheduleTrackChangeNotification(
            song: song,
            artwork: nil,
            isManualSelection: isManualSelection
        )
    }
}
