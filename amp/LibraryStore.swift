import Foundation
import MediaPlayer
import Combine
import os.signpost

// Instruments' built-in "Points of Interest" instrument auto-tracks
// signposts emitted under category "PointsOfInterest" — no recording
// options to configure. Differentiate by name prefix (library.*, etc.).
private let libraryPOI = OSSignposter(subsystem: "j0nathanb.amp", category: "PointsOfInterest")

// Resolver for durable (non-purgeable) cache files, shared by LibraryStore,
// CurrentTrackSnapshot, and the search index.
//
// These derived caches used to live in .cachesDirectory, which iOS reclaims
// under storage pressure while the app is backgrounded — increasingly likely
// the longer it sits idle (days/weeks). When they vanish, the next foreground
// pays a full MPMediaQuery rebuild of every Library tab + the search index,
// surfacing as multi-second loading spinners on every view except Now Playing.
// Application Support is not purged, so these survive a long idle (and a silent
// background jettison followed by state restoration).
//
// Deliberately NOT moved here: ArtworkCache stays in .cachesDirectory. It's
// large and trivially regenerable from the library — exactly what Caches is
// for — and moving it would bloat the app's non-purgeable footprint.
//
// Migration: existing installs have these files in Caches. The path change
// orphans them (Caches is auto-purged, so no cleanup needed) and costs a
// single rebuild on the first launch after update; durable from then on.
enum DurableStorage {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibraryCache", isDirectory: true)
    }

    // Application Support is not guaranteed to exist; create on demand.
    // createDirectory(withIntermediateDirectories: true) is idempotent and
    // cheap once the directory exists, so this is safe on every read/write.
    static func url(for fileName: String) -> URL {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }
}

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

    // Content signature (stable FNV-1a over the sorted song persistentID set)
    // of the library as of the last songs rebuild. Lets libraryDidChange tell
    // a real add/remove apart from a play-count / metadata-only bump and skip
    // the expensive song-derived rebuilds in the latter case. In-memory only:
    // ensureSongs has no disk cache, so this is re-established on every launch
    // by the unconditional songs load before any change notification can fire.
    private var songContentSignature: UInt64?

    // Per-tab cache files. See the VersionedLibraryCache comment above
    // for why we keep these separate rather than one consolidated blob.
    private static func cacheURL(_ name: String) -> URL {
        DurableStorage.url(for: name)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sourceDidChange),
            name: .ampLibrarySourceDidChange,
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

        // Disk caches are music-mode only: the folder source (Phase 3) is
        // itself a disk-cached derived structure, so caching its output
        // here would be a second copy with the wrong invalidation guard
        // (loadCache checks MPMediaLibrary.lastModifiedDate).
        if LibraryModeService.shared.mode == .music,
           let cached = await Self.loadCache(Self.albumsCacheURL, type: PersistedAlbums.self) {
            albums = cached.albums
            albumSections = LetterSection.bucket(cached.albums) { $0.title }
            albumsState = .loaded
            libraryPOI.endInterval("library.ensureAlbums", state, "count: \(cached.albums.count) (cache)")
            print("[PERF] ensureAlbums count=\(cached.albums.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms (cache hit)")
            return
        }

        await rebuildAlbums()
        albumsState = .loaded
    }

    // Rebuild Albums from the live library, publish, and persist the cache.
    // Deliberately leaves albumsState untouched: ensureAlbums() owns the
    // first-load loading→loaded flip, while libraryDidChange() calls this
    // directly to refresh an already-.loaded tab WITHOUT dropping to a
    // spinner — the current rows stay on screen until the fresh ones swap in.
    private func rebuildAlbums() async {
        let state = libraryPOI.beginInterval("library.rebuildAlbums")
        let t0 = Date()
        // Mode captured before the detached work; re-checked after (the
        // CLAUDE.md fail-safe pattern). A mode switch mid-build means this
        // result belongs to the old source — publishing it would stomp the
        // new mode's rows, and saving it would poison the music cache with
        // cross-source data. sourceDidChange has already queued a rebuild
        // for the new mode, so discarding is safe.
        let modeAtBuild = LibraryModeService.shared.mode
        let loaded = await Task.detached(priority: .userInitiated) {
            let albums = LibraryService.shared.getAllAlbums()
            return (albums, LetterSection.bucket(albums) { $0.title })
        }.value
        guard LibraryModeService.shared.mode == modeAtBuild else {
            print("📚 rebuildAlbums: mode switched mid-build — discarding")
            return
        }
        albums = loaded.0
        albumSections = loaded.1
        libraryPOI.endInterval("library.rebuildAlbums", state, "count: \(loaded.0.count)")
        print("[PERF] ensureAlbums count=\(loaded.0.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        if modeAtBuild == .music {
            Self.saveCache(
                PersistedAlbums(
                    version: PersistedAlbums.currentVersion,
                    libraryLastModified: MPMediaLibrary.default().lastModifiedDate,
                    albums: loaded.0
                ),
                to: Self.albumsCacheURL
            )
        }
    }

    func ensureArtists() async {
        guard artistsState == .idle else { return }
        artistsState = .loading
        let state = libraryPOI.beginInterval("library.ensureArtists")
        let t0 = Date()

        if LibraryModeService.shared.mode == .music,
           let cached = await Self.loadCache(Self.artistsCacheURL, type: PersistedArtists.self) {
            artists = cached.artists
            artistAlbumCounts = cached.albumCounts
            artistSections = LetterSection.bucket(cached.artists) { $0.name }
            artistsState = .loaded
            libraryPOI.endInterval("library.ensureArtists", state, "count: \(cached.artists.count) (cache)")
            print("[PERF] ensureArtists count=\(cached.artists.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms (cache hit)")
            return
        }

        await rebuildArtists()
        artistsState = .loaded
    }

    // See rebuildAlbums() for why this is split out and leaves state alone.
    private func rebuildArtists() async {
        let state = libraryPOI.beginInterval("library.rebuildArtists")
        let t0 = Date()
        // See rebuildAlbums for the mode capture/re-check rationale.
        let modeAtBuild = LibraryModeService.shared.mode
        let loaded = await Task.detached(priority: .userInitiated) {
            let rows = LibraryService.shared.getAllArtistsWithAlbumCounts()
            let artists = rows.map { $0.artist }
            var counts: [MPMediaEntityPersistentID: Int] = [:]
            counts.reserveCapacity(rows.count)
            for row in rows { counts[row.artist.id] = row.albumCount }
            return (artists, counts, LetterSection.bucket(artists) { $0.name })
        }.value
        guard LibraryModeService.shared.mode == modeAtBuild else {
            print("📚 rebuildArtists: mode switched mid-build — discarding")
            return
        }
        artists = loaded.0
        artistAlbumCounts = loaded.1
        artistSections = loaded.2
        libraryPOI.endInterval("library.rebuildArtists", state, "count: \(loaded.0.count)")
        print("[PERF] ensureArtists count=\(loaded.0.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        if modeAtBuild == .music {
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
    }

    func ensureSongs() async {
        guard songsState == .idle else { return }
        songsState = .loading
        await rebuildSongs()
        songsState = .loaded
    }

    // See rebuildAlbums() for why this is split out and leaves state alone.
    // Songs are deliberately not disk-cached (see the persisted-cache note up
    // top), so unlike the other tabs this has no save step.
    private func rebuildSongs() async {
        let state = libraryPOI.beginInterval("library.rebuildSongs")
        let t0 = Date()
        // See rebuildAlbums for the mode capture/re-check rationale.
        let modeAtBuild = LibraryModeService.shared.mode
        let loaded = await Task.detached(priority: .userInitiated) {
            // SongsScrubbableList displays songs sorted by title, so we
            // sort once here instead of recomputing in the view's body.
            let sorted = LibraryService.shared.getAllSongs()
                .sorted { LibraryService.nameOrder($0.title, $1.title) }
            return (sorted, LetterSection.bucket(sorted) { $0.title })
        }.value
        guard LibraryModeService.shared.mode == modeAtBuild else {
            print("📚 rebuildSongs: mode switched mid-build — discarding")
            return
        }
        songs = loaded.0
        songSections = loaded.1
        // Derived from the already-built array — free, and identical to the
        // getAllSongIDs() hash libraryDidChange computes for the diff check.
        songContentSignature = Self.contentSignature(loaded.0.map { $0.persistentID })
        libraryPOI.endInterval("library.rebuildSongs", state, "count: \(loaded.0.count)")
        print("[PERF] ensureSongs count=\(loaded.0.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    func ensureGenres() async {
        guard genresState == .idle else { return }
        genresState = .loading
        let state = libraryPOI.beginInterval("library.ensureGenres")
        let t0 = Date()

        if LibraryModeService.shared.mode == .music,
           let cached = await Self.loadCache(Self.genresCacheURL, type: PersistedGenres.self) {
            genres = cached.genres
            genreSections = LetterSection.bucket(cached.genres) { $0 }
            genresState = .loaded
            libraryPOI.endInterval("library.ensureGenres", state, "count: \(cached.genres.count) (cache)")
            print("[PERF] ensureGenres count=\(cached.genres.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms (cache hit)")
            return
        }

        await rebuildGenres()
        genresState = .loaded
    }

    // See rebuildAlbums() for why this is split out and leaves state alone.
    private func rebuildGenres() async {
        let state = libraryPOI.beginInterval("library.rebuildGenres")
        let t0 = Date()
        // See rebuildAlbums for the mode capture/re-check rationale.
        let modeAtBuild = LibraryModeService.shared.mode
        let raw = await LibraryService.shared.getAllGenres()
        guard LibraryModeService.shared.mode == modeAtBuild else {
            print("📚 rebuildGenres: mode switched mid-build — discarding")
            return
        }
        let sorted = raw.sorted(by: LibraryService.nameOrder)
        genres = sorted
        genreSections = LetterSection.bucket(sorted) { $0 }
        libraryPOI.endInterval("library.rebuildGenres", state, "count: \(sorted.count)")
        print("[PERF] ensureGenres count=\(sorted.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        if modeAtBuild == .music {
            Self.saveCache(
                PersistedGenres(
                    version: PersistedGenres.currentVersion,
                    libraryLastModified: MPMediaLibrary.default().lastModifiedDate,
                    genres: sorted
                ),
                to: Self.genresCacheURL
            )
        }
    }

    func ensurePlaylists() async {
        guard playlistsState == .idle else { return }
        playlistsState = .loading
        let state = libraryPOI.beginInterval("library.ensurePlaylists")
        let t0 = Date()

        if LibraryModeService.shared.mode == .music,
           let cached = await Self.loadCache(Self.playlistsCacheURL, type: PersistedPlaylists.self) {
            playlists = cached.playlists
            playlistsState = .loaded
            libraryPOI.endInterval("library.ensurePlaylists", state, "count: \(cached.playlists.count) (cache)")
            print("[PERF] ensurePlaylists count=\(cached.playlists.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms (cache hit)")
            return
        }

        await rebuildPlaylists()
        playlistsState = .loaded
    }

    // See rebuildAlbums() for why this is split out and leaves state alone.
    private func rebuildPlaylists() async {
        let state = libraryPOI.beginInterval("library.rebuildPlaylists")
        let t0 = Date()
        // See rebuildAlbums for the mode capture/re-check rationale.
        let modeAtBuild = LibraryModeService.shared.mode
        let loaded = await Task.detached(priority: .userInitiated) {
            LibraryService.shared.getPlaylists()
        }.value
        guard LibraryModeService.shared.mode == modeAtBuild else {
            print("📚 rebuildPlaylists: mode switched mid-build — discarding")
            return
        }
        playlists = loaded
        libraryPOI.endInterval("library.rebuildPlaylists", state, "count: \(loaded.count)")
        print("[PERF] ensurePlaylists count=\(loaded.count) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        if modeAtBuild == .music {
            Self.saveCache(
                PersistedPlaylists(
                    version: PersistedPlaylists.currentVersion,
                    libraryLastModified: MPMediaLibrary.default().lastModifiedDate,
                    playlists: loaded
                ),
                to: Self.playlistsCacheURL
            )
        }
    }

    // MARK: - Invalidation

    // Only reload tabs the user has actually visited. A user who has only
    // seen Albums shouldn't suddenly pay for a Songs scan just because
    // iOS fired a library-change notification.
    @objc private func libraryDidChange() {
        Task { @MainActor in
            // MP change notifications only matter while the Music source is
            // live. In folder mode the published rows are folder data — a
            // rebuild here would burn getAllSongIDs() scans for a library
            // the user isn't looking at. Music disk caches self-heal: the
            // lastModifiedDate guard rejects them on the next music-mode load.
            guard LibraryModeService.shared.mode == .music else {
                print("📚 libraryDidChange: folder mode active — ignoring MP library change")
                return
            }

            let reloadAlbums = albumsState == .loaded
            let reloadArtists = artistsState == .loaded
            let reloadSongs = songsState == .loaded
            let reloadGenres = genresState == .loaded
            let reloadPlaylists = playlistsState == .loaded

            // Diff-based invalidation. A MPMediaLibraryDidChange frequently
            // reflects only play-count / last-played metadata bumps (from
            // normal listening or a background sync), which leave the actual
            // song set — and the albums/artists/genres derived from it —
            // identical. Compute a cheap content signature of the current
            // song-ID set and skip the song-derived rebuilds when it matches
            // what the loaded data was built from. This is what stops a long
            // idle's coalesced resume notification from burning multi-second
            // getAllSongs() / getAllArtists() scans for no real change.
            //
            // Caveat: a pure in-place metadata edit that preserves every
            // persistentID (e.g. renaming an album in Apple Music without
            // adding/removing any track) doesn't move the signature, so it's
            // not picked up here — it's caught on the next cold launch by
            // loadCache's lastModifiedDate guard. Any add/remove of a track,
            // album, or artist DOES move the signature and rebuilds.
            //
            // Playlists are derived separately (membership can change with no
            // song-set change) and are cheap to rebuild (~30ms), so they
            // always refresh.
            //
            // Stage-and-swap throughout: the rebuild* helpers never reset a tab
            // to .idle, so visited tabs keep their current rows on screen while
            // a real change rebuilds in the background — no spinner storm.
            // No explicit cache purge: a real rebuild re-saves a fresh cache,
            // and any unvisited tab's now-stale cache is rejected by the
            // lastModifiedDate guard on its next load.
            let songDerivedLoaded = reloadAlbums || reloadArtists || reloadSongs || reloadGenres
            var songContentChanged = true
            if songDerivedLoaded, let baseline = songContentSignature {
                let current = await Task.detached(priority: .utility) {
                    Self.contentSignature(LibraryService.shared.getAllSongIDs())
                }.value
                songContentChanged = current != baseline
            }

            if songContentChanged {
                if reloadAlbums { await rebuildAlbums() }
                if reloadArtists { await rebuildArtists() }
                if reloadSongs { await rebuildSongs() }
                if reloadGenres { await rebuildGenres() }
            } else {
                print("📚 libraryDidChange: song content unchanged — skipped albums/artists/songs/genres rebuild")
            }

            if reloadPlaylists { await rebuildPlaylists() }
        }
    }

    // Library source switched (Music ⇄ Folder). Rebuild every visited tab
    // from the new active source, unconditionally — the source itself
    // changed, so the content-signature short-circuit is meaningless (and
    // the baseline belongs to the old source; drop it). Same stage-and-swap
    // as libraryDidChange: current rows stay on screen until the new
    // source's rows land. Unvisited tabs stay .idle and lazily load from
    // the new source on first visit.
    @objc private func sourceDidChange() {
        Task { @MainActor in
            songContentSignature = nil
            if albumsState == .loaded { await rebuildAlbums() }
            if artistsState == .loaded { await rebuildArtists() }
            if songsState == .loaded { await rebuildSongs() }
            if genresState == .loaded { await rebuildGenres() }
            if playlistsState == .loaded { await rebuildPlaylists() }
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

    // Order-independent content signature over a set of persistentIDs.
    // FNV-1a (not Swift's Hasher, whose seed is randomized per process) so the
    // value is reproducible: the songs rebuild derives it from its result and
    // libraryDidChange recomputes it from getAllSongIDs(), and the two must
    // agree for identical libraries. Sorting first makes it order-independent;
    // 23k UInt64s sort in well under a millisecond.
    private nonisolated static func contentSignature(_ ids: [MPMediaEntityPersistentID]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325          // FNV-1a offset basis
        let prime: UInt64 = 0x100000001b3
        hash = (hash ^ UInt64(ids.count)) &* prime     // length-sensitive
        for id in ids.sorted() {
            var v = id
            for _ in 0..<8 {
                hash = (hash ^ (v & 0xff)) &* prime
                v >>= 8
            }
        }
        return hash
    }

}
