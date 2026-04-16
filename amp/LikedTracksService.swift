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
}
