import Foundation
import MediaPlayer
import Combine
import os.signpost

// Instruments' built-in "Points of Interest" instrument auto-tracks
// signposts emitted under category "PointsOfInterest" — no recording
// options to configure. Differentiate by name prefix (library.*, etc.).
private let libraryPOI = OSSignposter(subsystem: "j0nathanb.amp", category: "PointsOfInterest")

// Typed letter-section container for alphabet-scrubber views. Generic so
// the same section shape works for albums, artists, songs, and genres.
struct LetterSection<T>: Identifiable {
    let letter: String
    let items: [T]
    var id: String { letter }

    // Alphabet-bucket a pre-sorted array. Input order is preserved within
    // each letter bucket — sort upstream by whatever ordering the list
    // should display (typically LibraryService.nameOrder).
    static func bucket(_ items: [T], key: (T) -> String) -> [LetterSection<T>] {
        let grouped = Dictionary(grouping: items) { AlphabetSectioning.key(for: key($0)) }
        return AlphabetSectioning.sortedKeys(grouped.keys).map { letter in
            LetterSection(letter: letter, items: grouped[letter] ?? [])
        }
    }
}

// Centralized, tab-lazy cache of the user's music library.
//
// Replaces the pattern where LibraryView held @State arrays and ran
// getAllSongs/getAllAlbums/getAllArtists/getPlaylists/getAllGenres on
// every view appear. Problems that resolved:
//
// 1. State survives view teardown (nav pop/push) so we don't re-hit
//    MPMediaQuery when the user returns to the Library tab.
// 2. Data arrives pre-sorted and pre-grouped into LetterSection arrays.
//    ArtistsScrubbableList/SongsScrubbableList/etc. previously recomputed
//    Dictionary(grouping:) + sorted on every body render (triggered by
//    audioPlayer ticks, state changes, etc.).
// 3. Lazy per-tab: Albums-only users never pay for the Songs scan.
//    ensureAlbums / ensureArtists / ensureSongs / ensureGenres /
//    ensurePlaylists are idempotent — first caller loads, later callers
//    are no-ops while the data is still current.
// 4. Invalidates on .MPMediaLibraryDidChange so edits made in Apple Music
//    don't leave the Library showing stale rows until next launch (mirrors
//    SearchIndexService's invalidation pattern).
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var albums: [Album] = []
    @Published private(set) var albumSections: [LetterSection<Album>] = []

    @Published private(set) var artists: [Artist] = []
    @Published private(set) var artistAlbumCounts: [MPMediaEntityPersistentID: Int] = [:]
    @Published private(set) var artistSections: [LetterSection<Artist>] = []

    @Published private(set) var songs: [Song] = []
    @Published private(set) var songSections: [LetterSection<Song>] = []

    @Published private(set) var genres: [String] = []
    @Published private(set) var genreSections: [LetterSection<String>] = []

    @Published private(set) var playlists: [Playlist] = []

    enum LoadState { case idle, loading, loaded }
    @Published private(set) var albumsState: LoadState = .idle
    @Published private(set) var artistsState: LoadState = .idle
    @Published private(set) var songsState: LoadState = .idle
    @Published private(set) var genresState: LoadState = .idle
    @Published private(set) var playlistsState: LoadState = .idle

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(libraryDidChange),
            name: .MPMediaLibraryDidChange,
            object: nil
        )
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
    }

    deinit {
        MPMediaLibrary.default().endGeneratingLibraryChangeNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Per-tab loaders

    func ensureAlbums() async {
        guard albumsState == .idle else { return }
        albumsState = .loading
        let state = libraryPOI.beginInterval("library.ensureAlbums")
        let t0 = Date()
        let loaded = await Task.detached(priority: .userInitiated) {
            let albums = LibraryService.shared.getAllAlbums()
            return (albums, LetterSection.bucket(albums) { $0.title })
        }.value
        albums = loaded.0
        albumSections = loaded.1
        albumsState = .loaded
        libraryPOI.endInterval("library.ensureAlbums", state, "count: \(loaded.0.count)")
        print("[PERF] ensureAlbums count=\(loaded.0.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    func ensureArtists() async {
        guard artistsState == .idle else { return }
        artistsState = .loading
        let state = libraryPOI.beginInterval("library.ensureArtists")
        let t0 = Date()
        let loaded = await Task.detached(priority: .userInitiated) {
            let rows = LibraryService.shared.getAllArtistsWithAlbumCounts()
            let artists = rows.map { $0.artist }
            var counts: [MPMediaEntityPersistentID: Int] = [:]
            counts.reserveCapacity(rows.count)
            for row in rows { counts[row.artist.id] = row.albumCount }
            return (artists, counts, LetterSection.bucket(artists) { $0.name })
        }.value
        artists = loaded.0
        artistAlbumCounts = loaded.1
        artistSections = loaded.2
        artistsState = .loaded
        libraryPOI.endInterval("library.ensureArtists", state, "count: \(loaded.0.count)")
        print("[PERF] ensureArtists count=\(loaded.0.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    func ensureSongs() async {
        guard songsState == .idle else { return }
        songsState = .loading
        let state = libraryPOI.beginInterval("library.ensureSongs")
        let t0 = Date()
        let loaded = await Task.detached(priority: .userInitiated) {
            // SongsScrubbableList displays songs sorted by title, so we
            // sort once here instead of recomputing in the view's body.
            let sorted = LibraryService.shared.getAllSongs()
                .sorted { LibraryService.nameOrder($0.title, $1.title) }
            return (sorted, LetterSection.bucket(sorted) { $0.title })
        }.value
        songs = loaded.0
        songSections = loaded.1
        songsState = .loaded
        libraryPOI.endInterval("library.ensureSongs", state, "count: \(loaded.0.count)")
        print("[PERF] ensureSongs count=\(loaded.0.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    func ensureGenres() async {
        guard genresState == .idle else { return }
        genresState = .loading
        let state = libraryPOI.beginInterval("library.ensureGenres")
        let t0 = Date()
        let raw = await LibraryService.shared.getAllGenres()
        let sorted = raw.sorted(by: LibraryService.nameOrder)
        genres = sorted
        genreSections = LetterSection.bucket(sorted) { $0 }
        genresState = .loaded
        libraryPOI.endInterval("library.ensureGenres", state, "count: \(sorted.count)")
        print("[PERF] ensureGenres count=\(sorted.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    func ensurePlaylists() async {
        guard playlistsState == .idle else { return }
        playlistsState = .loading
        let state = libraryPOI.beginInterval("library.ensurePlaylists")
        let t0 = Date()
        let loaded = await Task.detached(priority: .userInitiated) {
            LibraryService.shared.getPlaylists()
        }.value
        playlists = loaded
        playlistsState = .loaded
        libraryPOI.endInterval("library.ensurePlaylists", state, "count: \(loaded.count)")
        print("[PERF] ensurePlaylists count=\(loaded.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    // MARK: - Invalidation

    // Only reload tabs the user has actually visited. A user who has only
    // seen Albums shouldn't suddenly pay for a Songs scan just because
    // iOS fired a library-change notification.
    @objc private func libraryDidChange() {
        Task { @MainActor in
            let reloadAlbums = albumsState == .loaded
            let reloadArtists = artistsState == .loaded
            let reloadSongs = songsState == .loaded
            let reloadGenres = genresState == .loaded
            let reloadPlaylists = playlistsState == .loaded

            albumsState = .idle
            artistsState = .idle
            songsState = .idle
            genresState = .idle
            playlistsState = .idle

            if reloadAlbums { await ensureAlbums() }
            if reloadArtists { await ensureArtists() }
            if reloadSongs { await ensureSongs() }
            if reloadGenres { await ensureGenres() }
            if reloadPlaylists { await ensurePlaylists() }
        }
    }

}
