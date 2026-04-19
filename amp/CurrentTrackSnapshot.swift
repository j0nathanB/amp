import Foundation
import MediaPlayer

// Tiny sidecar file (~200-500 bytes) holding just enough state to hydrate
// the Now Playing UI and pre-load audio at cold launch, WITHOUT waiting
// for the full queue restore.
//
// What it buys us: the user's play button works within tens of
// milliseconds of app launch instead of hundreds. The full queue restore
// still happens on its normal path and is reconciled with the eager state
// in QueueManagerService.loadQueue.
//
// Why a separate file instead of reading the current track out of the
// main queue file: the main queue file holds ~23k track IDs + shuffle
// state + grouping; even the post-#3 binary-plist decode is ~5ms. The
// 500-byte snapshot is ~microseconds to read, so eager startup is
// bounded by the AVAudioFile open (~30-50ms), not by disk decode.
//
// Guards: `version` gates struct shape changes (cache miss on mismatch);
// `.atomic` write at the save site eliminates the truncated-file case at
// the source. Matches the SearchIndex / LibraryStore / QueueBinaryCoder
// pattern — the atomic-writes rule is non-negotiable for any disk cache
// in this project.
struct CurrentTrackSnapshot: Codable {
    let version: Int
    let savedAt: Date
    let song: Song
    let assetURL: URL
    let playbackPosition: TimeInterval
    let currentIndex: Int?

    static let currentVersion = 1

    private static var diskURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("current_track_snapshot.plist")
    }

    // Sync read — file is ~500 bytes, read happens once at app launch
    // before any frame needs to render. Keeping it sync simplifies the
    // caller: eager load is a straight line in AudioPlayerService.init()
    // rather than a Task await dance. If you're tempted to make this
    // async, measure first — the sync cost is negligible and the async
    // version complicates the init ordering (eager load must commit
    // before queueManager's loadQueueOnce task fires, or the guards in
    // loadQueue misfire).
    static func loadFromDisk() -> CurrentTrackSnapshot? {
        guard let url = diskURL,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            let snapshot = try PropertyListDecoder().decode(CurrentTrackSnapshot.self, from: data)
            guard snapshot.version == currentVersion else {
                print("⚡ CurrentTrackSnapshot: version mismatch (\(snapshot.version) vs \(currentVersion)) — discarding and cleaning up")
                // Self-heal: delete the stale file so we don't re-read,
                // re-reject, re-log on every subsequent cold launch. The
                // next saveQueue writes a fresh snapshot in the current
                // format.
                removeFromDisk()
                return nil
            }
            return snapshot
        } catch {
            print("⚡ CurrentTrackSnapshot: decode failed — \(error). Cleaning up and falling through to full queue restore.")
            // A corrupt file (somehow escaped the atomic-write guarantee)
            // would re-fail every launch. Delete so the next save starts
            // fresh.
            removeFromDisk()
            return nil
        }
    }

    // Async write, fire-and-forget. .atomic is load-bearing: without it,
    // an app-kill mid-write leaves a half-written plist that would either
    // decode to nil (best case) or to silently-wrong data (worst case,
    // wrong track or position on next launch). See atomic-writes memory.
    static func saveToDisk(_ snapshot: CurrentTrackSnapshot) {
        guard let url = diskURL else { return }
        Task.detached(priority: .utility) {
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
                print(String(format: "⚡ CurrentTrackSnapshot: saved %dB — %@ at %.3fs", data.count, snapshot.song.title, snapshot.playbackPosition))
            } catch {
                print("⚡ CurrentTrackSnapshot: save failed — \(error)")
            }
        }
    }

    // Called when currentTrack is cleared (stop, queue cleared) so next
    // launch doesn't eagerly hydrate a track the user has dismissed.
    static func removeFromDisk() {
        guard let url = diskURL else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
