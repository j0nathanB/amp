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

// MARK: - Persisted cache shapes
//
// One file per tab, mirroring the lazy-per-tab design of LibraryStore.
// A user who only visits Albums never pays the Artists-decode cost, and
// changing a single model (e.g., adding a field to Artist) bumps only
// that tab's currentVersion.
//
// What's persisted is the *derived* output of the ensure* work — the
// sorted flat arrays, plus Artists' album-count dict — NOT the raw
// MPMediaItem scan. LetterSection buckets are re-derived on load;
// bucketing is cheap (<10ms on 1.4k items) and persisting it would
// double file size for no win.
//
// Songs are deliberately NOT cached: ensureSongs is already ~280ms and
// persisting 23k songs would 5x total cache size on disk.
//
// Both guards below mirror SearchIndexService. Don't strip either.
// - version != currentVersion → cache miss (protects TestFlight users
//   from crash-on-launch when someone ships a struct change).
// - libraryLastModified < current → cache miss (picks up external
//   library edits even when MPMediaLibraryDidChange didn't fire).
// Both fall through to the same rebuild-and-save path.
protocol VersionedLibraryCache: Codable {
    static var currentVersion: Int { get }
    var version: Int { get }
    var libraryLastModified: Date { get }
}

struct PersistedAlbums: VersionedLibraryCache {
    let version: Int
    let libraryLastModified: Date
    let albums: [Album]
    static let currentVersion = 1
}

struct PersistedArtists: VersionedLibraryCache {
    let version: Int
    let libraryLastModified: Date
    let artists: [Artist]
    let albumCounts: [MPMediaEntityPersistentID: Int]
    static let currentVersion = 1
}

struct PersistedGenres: VersionedLibraryCache {
    let version: Int
    let libraryLastModified: Date
    let genres: [String]
    static let currentVersion = 1
}

struct PersistedPlaylists: VersionedLibraryCache {
    let version: Int
    let libraryLastModified: Date
    let playlists: [Playlist]
    static let currentVersion = 1
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

    // Per-tab cache files. See the VersionedLibraryCache comment above
    // for why we keep these separate rather than one consolidated blob.
    private static func cacheURL(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
    }
    private static let albumsCacheURL = cacheURL("LibraryAlbums.cache")
    private static let artistsCacheURL = cacheURL("LibraryArtists.cache")
    private static let genresCacheURL = cacheURL("LibraryGenres.cache")
    private static let playlistsCacheURL = cacheURL("LibraryPlaylists.cache")
    private static let allCacheURLs: [URL] = [
        albumsCacheURL, artistsCacheURL, genresCacheURL, playlistsCacheURL
    ]

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

        if let cached = await Self.loadCache(Self.albumsCacheURL, type: PersistedAlbums.self) {
            albums = cached.albums
            albumSections = LetterSection.bucket(cached.albums) { $0.title }
            albumsState = .loaded
            libraryPOI.endInterval("library.ensureAlbums", state, "count: \(cached.albums.count) (cache)")
            print("[PERF] ensureAlbums count=\(cached.albums.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms (cache hit)")
            return
        }

        let loaded = await Task.detached(priority: .userInitiated) {
            let albums = LibraryService.shared.getAllAlbums()
            return (albums, LetterSection.bucket(albums) { $0.title })
        }.value
        albums = loaded.0
        albumSections = loaded.1
        albumsState = .loaded
        libraryPOI.endInterval("library.ensureAlbums", state, "count: \(loaded.0.count)")
        print("[PERF] ensureAlbums count=\(loaded.0.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        Self.saveCache(
            PersistedAlbums(
                version: PersistedAlbums.currentVersion,
                libraryLastModified: MPMediaLibrary.default().lastModifiedDate,
                albums: loaded.0
            ),
            to: Self.albumsCacheURL
        )
    }

    func ensureArtists() async {
        guard artistsState == .idle else { return }
        artistsState = .loading
        let state = libraryPOI.beginInterval("library.ensureArtists")
        let t0 = Date()

        if let cached = await Self.loadCache(Self.artistsCacheURL, type: PersistedArtists.self) {
            artists = cached.artists
            artistAlbumCounts = cached.albumCounts
            artistSections = LetterSection.bucket(cached.artists) { $0.name }
            artistsState = .loaded
            libraryPOI.endInterval("library.ensureArtists", state, "count: \(cached.artists.count) (cache)")
            print("[PERF] ensureArtists count=\(cached.artists.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms (cache hit)")
            return
        }

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

        Self.saveCache(
            PersistedArtists(
                version: PersistedArtists.currentVersion,
                libraryLastModified: MPMediaLibrary.default().lastModifiedDate,
                artists: loaded.0,
                albumCounts: loaded.1
            ),
            to: Self.artistsCacheURL
        )
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

        if let cached = await Self.loadCache(Self.genresCacheURL, type: PersistedGenres.self) {
            genres = cached.genres
            genreSections = LetterSection.bucket(cached.genres) { $0 }
            genresState = .loaded
            libraryPOI.endInterval("library.ensureGenres", state, "count: \(cached.genres.count) (cache)")
            print("[PERF] ensureGenres count=\(cached.genres.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms (cache hit)")
            return
        }

        let raw = await LibraryService.shared.getAllGenres()
        let sorted = raw.sorted(by: LibraryService.nameOrder)
        genres = sorted
        genreSections = LetterSection.bucket(sorted) { $0 }
        genresState = .loaded
        libraryPOI.endInterval("library.ensureGenres", state, "count: \(sorted.count)")
        print("[PERF] ensureGenres count=\(sorted.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        Self.saveCache(
            PersistedGenres(
                version: PersistedGenres.currentVersion,
                libraryLastModified: MPMediaLibrary.default().lastModifiedDate,
                genres: sorted
            ),
            to: Self.genresCacheURL
        )
    }

    func ensurePlaylists() async {
        guard playlistsState == .idle else { return }
        playlistsState = .loading
        let state = libraryPOI.beginInterval("library.ensurePlaylists")
        let t0 = Date()

        if let cached = await Self.loadCache(Self.playlistsCacheURL, type: PersistedPlaylists.self) {
            playlists = cached.playlists
            playlistsState = .loaded
            libraryPOI.endInterval("library.ensurePlaylists", state, "count: \(cached.playlists.count) (cache)")
            print("[PERF] ensurePlaylists count=\(cached.playlists.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms (cache hit)")
            return
        }

        let loaded = await Task.detached(priority: .userInitiated) {
            LibraryService.shared.getPlaylists()
        }.value
        playlists = loaded
        playlistsState = .loaded
        libraryPOI.endInterval("library.ensurePlaylists", state, "count: \(loaded.count)")
        print("[PERF] ensurePlaylists count=\(loaded.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        Self.saveCache(
            PersistedPlaylists(
                version: PersistedPlaylists.currentVersion,
                libraryLastModified: MPMediaLibrary.default().lastModifiedDate,
                playlists: loaded
            ),
            to: Self.playlistsCacheURL
        )
    }

    // MARK: - Invalidation

    // Only reload tabs the user has actually visited. A user who has only
    // seen Albums shouldn't suddenly pay for a Songs scan just because
    // iOS fired a library-change notification.
    @objc private func libraryDidChange() {
        // Purge cache files. The lastModifiedDate guard alone would also
        // force a miss on next load (new library date > cached date), but
        // explicit deletion matches SearchIndexService.libraryDidChange and
        // keeps intent legible.
        Task.detached(priority: .utility) {
            for url in Self.allCacheURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

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

    // MARK: - Cache helpers (shared across all four tab caches)

    // Off-main decode + both guards (version, libraryLastModified). Any
    // decode error — including truncated/corrupt files — returns nil and
    // the caller falls through to the rebuild path. The PR acceptance test
    // in ampTests exercises that truncation branch directly.
    private static func loadCache<T: VersionedLibraryCache>(_ url: URL, type: T.Type) async -> T? {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                let cached = try JSONDecoder().decode(T.self, from: data)
                guard cached.version == T.currentVersion else {
                    print("📚 \(url.lastPathComponent) version mismatch (\(cached.version) vs \(T.currentVersion)) — discarding")
                    return nil
                }
                let current = MPMediaLibrary.default().lastModifiedDate
                guard cached.libraryLastModified >= current else {
                    print("📚 \(url.lastPathComponent) stale (cache: \(cached.libraryLastModified), library: \(current)) — discarding")
                    return nil
                }
                return cached
            } catch {
                print("📚 \(url.lastPathComponent) decode failed: \(error) — rebuilding")
                return nil
            }
        }.value
    }

    // Off-main encode + atomic write. .atomic is load-bearing: without it,
    // an app kill mid-write can leave a half-written file that decodes into
    // structurally-valid-but-wrong data (half the sections populated, wrong
    // artist counts) with no crash to signal the problem. Keep .atomic.
    private static func saveCache<T: Codable>(_ value: T, to url: URL) {
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(value)
                try data.write(to: url, options: .atomic)
                print("📚 \(url.lastPathComponent) saved (\(data.count / 1024)KB)")
            } catch {
                print("📚 \(url.lastPathComponent) save failed: \(error)")
            }
        }
    }

}
