import Foundation
import AVFoundation
import MediaPlayer

protocol PlaybackEngineDelegate: AnyObject {
    func playbackDidFinish(successfully: Bool)
    func playbackTimeDidUpdate(_ time: TimeInterval)
}

class PlaybackEngineService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    weak var delegate: PlaybackEngineDelegate?
    
    private var player: AVAudioPlayer?
    private var timer: Timer?
    
    @Published var isPlaying = false
    @Published var songDuration: TimeInterval = 0.0
    @Published var playbackTime: TimeInterval = 0.0
    @Published var currentOutputName: String = ""
    
    override init() {
        super.init()
        updateCurrentOutputName()
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(handleRouteChange), 
            name: AVAudioSession.routeChangeNotification, 
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
    }
    
    // MARK: - Playback Control
    
    func play(song: Song) {
        guard let url = getAudioURL(for: song) else {
            print("❌ No audio URL found for song: \(song.title)")
            return
        }
        
        commonPlay(url: url)
        updateNowPlayingInfo(for: song)
    }
    
    func playPause() {
        guard let player = player else { return }
        
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }
    
    func stop() {
        player?.stop()
        isPlaying = false
        playbackTime = 0.0
        stopTimer()
    }
    
    func seek(to time: TimeInterval) {
        player?.currentTime = time
        playbackTime = time
    }
    
    func loadWithoutPlaying(song: Song) {
        guard let url = getAudioURL(for: song) else {
            print("❌ No audio URL found for song: \(song.title)")
            return
        }
        
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
    
    private func commonPlay(url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            
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
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            
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
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateNowPlayingInfo(for song: Song) {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = songDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    @objc private func handleRouteChange() {
        updateCurrentOutputName()
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