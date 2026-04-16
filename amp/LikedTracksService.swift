import Foundation
import MediaPlayer
import Combine

// Spec §9.1: the one exception to the "no local state" rule. When the user
// taps the heart button, that track's liked status is persisted locally in
// amp's own data store — never written back to iTunes.
//
// Storage: UserDefaults-backed Set<MPMediaEntityPersistentID>. Chosen over
// SwiftData because the payload is a flat set of 8-byte IDs with no
// per-track metadata; migrating to SwiftData later (if we add date-liked
// sorts or iCloud sync) is a one-shot conversion.
//
// .m3u export arrives in Phase F.

final class LikedTracksService: ObservableObject {
    static let shared = LikedTracksService()

    private static let storageKey = "amp.likedTrackIDs"

    @Published private(set) var likedIDs: Set<MPMediaEntityPersistentID>

    private init() {
        if let stored = UserDefaults.standard.array(forKey: Self.storageKey) as? [NSNumber] {
            self.likedIDs = Set(stored.map { $0.uint64Value })
        } else {
            self.likedIDs = []
        }
    }

    func isLiked(trackID: MPMediaEntityPersistentID) -> Bool {
        likedIDs.contains(trackID)
    }

    func toggleLike(trackID: MPMediaEntityPersistentID) {
        if likedIDs.contains(trackID) {
            likedIDs.remove(trackID)
        } else {
            likedIDs.insert(trackID)
        }
        persist()
    }

    func allLikedTrackIDs() -> Set<MPMediaEntityPersistentID> {
        likedIDs
    }

    private func persist() {
        let array = likedIDs.map { NSNumber(value: $0) }
        UserDefaults.standard.set(array, forKey: Self.storageKey)
    }

    // MARK: - .m3u export (§7.9, §9.1)
    //
    // Writes a temp .m3u file the user can share via the system sheet. The
    // format is "extended M3U" — #EXTM3U header + one #EXTINF per track
    // followed by a pseudo filename derived from "{artist} - {title}.mp3".
    // Since MPMediaLibrary track URLs are `ipod-library://` and not usable
    // from other apps, the pseudo filename lets importers (iTunes / Apple
    // Music / etc.) match by metadata rather than path. Duration is -1
    // (unknown) because Song doesn't currently carry a duration field;
    // loading it for every track would add an MPMediaQuery per line.

    enum ExportError: Error {
        case noLikedTracks
        case writeFailed(underlying: Error)
    }

    func generateM3UFile() throws -> URL {
        guard !likedIDs.isEmpty else { throw ExportError.noLikedTracks }

        var content = "#EXTM3U\n"
        for id in likedIDs.sorted() {
            guard let song = LibraryService.shared.getSong(by: id) else { continue }
            let displayName = "\(song.artist) - \(song.title)"
            let sanitized = displayName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\n", with: " ")
            content += "#EXTINF:-1,\(displayName)\n"
            content += "\(sanitized).mp3\n"
        }

        let tempDir = FileManager.default.temporaryDirectory
        let stamp = DateFormatter.m3uStamp.string(from: Date())
        let url = tempDir.appendingPathComponent("amp-liked-\(stamp).m3u")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }
    }
}

private extension DateFormatter {
    static let m3uStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
