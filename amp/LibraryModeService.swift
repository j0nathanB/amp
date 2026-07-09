import Foundation

// Which library the app is showing: the iOS Music library or the user's
// custom folder roots. Exactly one is active at a time — folder mode hides
// the Music library everywhere (Library tabs, search, playlists), and
// vice-versa. See dev/FOLDER_LIBRARY_TOGGLE_PLAN.md for the locked
// decisions this implements.
// Named LibrarySourceMode (not LibraryMode) because LibraryView already
// owns `LibraryMode` for its tab chips (albums/artists/songs/...).
enum LibrarySourceMode: String {
    case music
    case folder
}

extension Notification.Name {
    // Posted after a mode switch completes — the local counterpart of
    // .MPMediaLibraryDidChange. LibraryStore and the search index listen
    // to both and reload from the (new) active source.
    static let ampLibrarySourceDidChange = Notification.Name("AmpLibrarySourceDidChange")
}

final class LibraryModeService: ObservableObject {
    static let shared = LibraryModeService()

    private static let storageKey = "amp.libraryMode"

    @Published private(set) var mode: LibrarySourceMode

    private init() {
        mode = LibrarySourceMode(rawValue: UserDefaults.standard.string(forKey: Self.storageKey) ?? "") ?? .music
    }

    // The switch sequence (plan decisions #5/#6). Order matters:
    //
    // 1. Stop playback entirely and erase the queue — in-memory, persisted
    //    file, and the Now-Playing snapshot (eraseQueue's currentTrack = nil
    //    didSet removes it from disk). Nothing from the old source lingers,
    //    and no snapshot can ever restore a current track that has no
    //    backing queue.
    // 2. Flip and persist the mode, so everything downstream reads the new
    //    source.
    // 3. Swap the per-mode liked set (each mode's likes live under their
    //    own UserDefaults key; neither is destroyed by the other).
    // 4. Announce, so LibraryStore rebuilds its visited tabs and the search
    //    index installs the new source's index.
    func setMode(_ newMode: LibrarySourceMode) {
        guard newMode != mode else { return }
        print("📚 [LibraryMode] Switching \(mode.rawValue) → \(newMode.rawValue)")

        AudioPlayerService.shared.stopPlaybackAndEraseQueue()

        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.storageKey)

        LikedTracksService.shared.reloadForActiveMode()

        NotificationCenter.default.post(name: .ampLibrarySourceDidChange, object: nil)
    }
}
