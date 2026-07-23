import Foundation
import AVFoundation

// The folder-mode library backbone (Phase 3 of
// dev/FOLDER_LIBRARY_TOGGLE_PLAN.md): user-granted folder roots
// (security-scoped bookmarks), the scanned track catalog, and the disk
// persistence for both. FolderLibrarySource reads the catalog;
// FolderSettingsView drives add/remove/rescan; PlaybackEngineService
// resolves playable URLs and holds root scopes across playback.

// MARK: - Folder root

// One folder the user granted access to. bookmarkData is the
// security-scoped bookmark; it survives relaunches and is re-resolved at
// startup. A root that fails to resolve (moved/deleted/revoked) is
// surfaced as stale in FolderSettingsView — never silently dropped
// (plan decision #7).
struct FolderRoot: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
    var addedAt: Date
    var lastScanCompletedAt: Date?
    var trackCount: Int
}

// MARK: - Synthetic ids

// FNV-1a 64-bit over a canonical string. Fixed algorithm — NEVER Swift's
// Hasher, whose per-process seed would invalidate every persisted queue,
// liked set, and snapshot on relaunch. Same primitive LibraryStore uses
// for its content signature. Collisions are ~10⁻¹¹ at personal-library
// scale but the catalog build still detects and salts them (see
// FolderLibraryService.buildCatalog).
enum FolderID {
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325          // offset basis
        let prime: UInt64 = 0x100000001b3
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        return hash
    }

    static func track(rootID: UUID, relativePath: String, salt: Int = 0) -> UInt64 {
        let base = "track|\(rootID.uuidString)|\(relativePath)"
        return fnv1a64(salt == 0 ? base : "\(base)|salt\(salt)")
    }

    static func album(albumArtist: String, album: String) -> UInt64 {
        fnv1a64("album|\(albumArtist.lowercased())|\(album.lowercased())")
    }

    static func artist(name: String) -> UInt64 {
        fnv1a64("artist|\(name.lowercased())")
    }

    static func playlist(rootID: UUID, relativePath: String, salt: Int = 0) -> UInt64 {
        let base = "playlist|\(rootID.uuidString)|\(relativePath)"
        return fnv1a64(salt == 0 ? base : "\(base)|salt\(salt)")
    }
}

// MARK: - Catalog model

// One scanned audio file. song.persistentID is the synthetic track id.
// albumID/artistID are precomputed at scan time so Phase 4's grouping is
// pure wiring.
struct FolderTrack: Codable {
    let song: Song
    let rootID: UUID
    let relativePath: String
    let duration: TimeInterval
    let albumArtist: String
    let albumID: UInt64
    let artistID: UInt64
}

// One parsed-and-resolved .m3u/.pls playlist. trackIDs are catalog track
// ids in playlist-file order; unresolvable entries were dropped at build
// time (plan decision #3). id is synthetic (FolderID.playlist over the
// playlist file's root + relative path) — stable across rescans.
struct FolderPlaylist: Codable {
    let id: UInt64
    let name: String
    let trackIDs: [UInt64]
}

// The persisted, derived catalog — what a warm launch loads instead of
// re-reading AVAsset tags. tracks are pre-sorted by title (the Songs tab
// order), playlists by name, at build time.
// v1 → v2: added playlists (Phase 5). Old catalogs fail decode / the
// version gate and rebuild on the next scan+load.
struct FolderCatalogData: Codable {
    let version: Int
    let tracks: [FolderTrack]
    let playlists: [FolderPlaylist]

    static let currentVersion = 2
    static let empty = FolderCatalogData(version: currentVersion, tracks: [], playlists: [])
}

// Thread-safe in-memory catalog snapshot. LibrarySource methods are
// synchronous and get called from detached tasks (LibraryStore rebuilds)
// as well as the main thread, so reads must not require an actor hop —
// same reasoning as HybridSearchIndex's queue-guarded caches.
final class FolderCatalog {
    private let lock = NSLock()
    private var tracksByTitle: [FolderTrack] = []
    private var songsByTitle: [Song] = []
    private var byID: [UInt64: FolderTrack] = [:]
    private var playlistsByName: [FolderPlaylist] = []
    private var playlistsByID: [UInt64: FolderPlaylist] = [:]

    func install(_ data: FolderCatalogData) {
        var index: [UInt64: FolderTrack] = [:]
        index.reserveCapacity(data.tracks.count)
        for track in data.tracks { index[track.song.persistentID] = track }
        var playlistIndex: [UInt64: FolderPlaylist] = [:]
        for playlist in data.playlists { playlistIndex[playlist.id] = playlist }
        lock.lock()
        tracksByTitle = data.tracks
        songsByTitle = data.tracks.map { $0.song }
        byID = index
        playlistsByName = data.playlists
        playlistsByID = playlistIndex
        lock.unlock()
    }

    var allSongs: [Song] {
        lock.lock(); defer { lock.unlock() }
        return songsByTitle
    }

    // Full track rows (title order) — grouping queries and the folder
    // search-index build read these.
    var allTracks: [FolderTrack] {
        lock.lock(); defer { lock.unlock() }
        return tracksByTitle
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return songsByTitle.count
    }

    func track(for id: UInt64) -> FolderTrack? {
        lock.lock(); defer { lock.unlock() }
        return byID[id]
    }

    func songs(for ids: [UInt64]) -> [UInt64: Song] {
        lock.lock(); defer { lock.unlock() }
        var result: [UInt64: Song] = [:]
        result.reserveCapacity(ids.count)
        for id in ids {
            if let track = byID[id] { result[id] = track.song }
        }
        return result
    }

    var allPlaylists: [FolderPlaylist] {
        lock.lock(); defer { lock.unlock() }
        return playlistsByName
    }

    func playlist(for id: UInt64) -> FolderPlaylist? {
        lock.lock(); defer { lock.unlock() }
        return playlistsByID[id]
    }
}

// MARK: - Service

final class FolderLibraryService: ObservableObject {
    static let shared = FolderLibraryService()

    // Main-thread published state for FolderSettingsView.
    @Published private(set) var roots: [FolderRoot] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: (discovered: Int, processed: Int)?
    @Published private(set) var staleRootIDs: Set<UUID> = []

    // Scanned-but-not-loaded catalog awaiting the explicit "Load library"
    // action (dogfood feedback 2026-07-11): scanning only STAGES results;
    // nothing reaches the live library/queue/search until the user loads.
    // nil count = nothing staged.
    @Published private(set) var stagedTrackCount: Int?
    private var stagedCatalog: FolderCatalogData?

    let catalog = FolderCatalog()

    private static let rootsFileURL = DurableStorage.url(for: "FolderRoots.json")
    private static let catalogFileURL = DurableStorage.url(for: "FolderCatalog.json")

    // Security-scope bookkeeping. Counts per root; stopAccessing fires only
    // at zero (plan watch-out: playback holds a root's scope for a track's
    // lifetime while a scan may bracket the same root — naive pairing would
    // let the scan's stop tear down playback's grant mid-track).
    //
    // scopeHeld tracks whether startAccessing actually took a scope for the
    // root: it returns false for URLs that don't need one (folders inside
    // the app's own container, "On My iPhone" locations) — that's "no scope
    // required", NOT "access denied", so we proceed without it and skip the
    // matching stopAccessing.
    private let accessLock = NSLock()
    private var resolvedURLs: [UUID: URL] = [:]
    private var accessCounts: [UUID: Int] = [:]
    private var scopeHeld: Set<UUID> = []

    private init() {
        loadRoots()
        loadCatalog()
        resolveAllBookmarks()
    }

    // MARK: - Roots management

    // Called with the URL from the system folder picker, which arrives
    // with an active (transient) scope grant. Capture the persistent
    // bookmark inside that grant, then release — long-lived access goes
    // through beginAccess/endAccess on the re-resolved URL.
    func addFolder(pickedURL url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            // Re-picking an already-added folder refreshes its bookmark
            // (the stale-root recovery path) instead of duplicating it.
            if let existing = roots.firstIndex(where: {
                resolvedURL(for: $0.id)?.standardizedFileURL == url.standardizedFileURL
            }) {
                roots[existing].bookmarkData = bookmark
                staleRootIDs.remove(roots[existing].id)
                saveRoots()
                resolveBookmark(for: roots[existing])
                print("📁 Refreshed bookmark for existing root: \(roots[existing].displayName)")
            } else {
                let root = FolderRoot(
                    id: UUID(),
                    displayName: url.lastPathComponent,
                    bookmarkData: bookmark,
                    addedAt: Date(),
                    lastScanCompletedAt: nil,
                    trackCount: 0
                )
                roots.append(root)
                saveRoots()
                resolveBookmark(for: root)
                print("📁 Added folder root: \(root.displayName)")
            }
            rescan()
        } catch {
            print("📁 ❌ Failed to capture bookmark for \(url.lastPathComponent): \(error)")
        }
    }

    func removeFolder(id: UUID) {
        roots.removeAll { $0.id == id }
        staleRootIDs.remove(id)
        accessLock.lock()
        resolvedURLs[id] = nil
        accessCounts[id] = nil
        accessLock.unlock()
        saveRoots()
        rescan()
    }

    // MARK: - Bookmark resolution

    private func resolveAllBookmarks() {
        for root in roots { resolveBookmark(for: root) }
    }

    private func resolveBookmark(for root: FolderRoot) {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: root.bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            accessLock.lock()
            resolvedURLs[root.id] = url
            accessLock.unlock()
            if stale {
                // Resolvable-but-stale: usable this session; refresh the
                // stored bookmark inside a scope grant so next launch is
                // clean. iOS 17+ invalidates bookmarks more aggressively —
                // staleness is operational state, not an error.
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                       let idx = roots.firstIndex(where: { $0.id == root.id }) {
                        roots[idx].bookmarkData = fresh
                        saveRoots()
                        print("📁 Refreshed stale bookmark for \(root.displayName)")
                    }
                }
            }
            staleRootIDs.remove(root.id)
        } catch {
            print("📁 ⚠️ Bookmark resolution failed for \(root.displayName): \(error)")
            staleRootIDs.insert(root.id)
        }
    }

    private func resolvedURL(for rootID: UUID) -> URL? {
        accessLock.lock(); defer { accessLock.unlock() }
        return resolvedURLs[rootID]
    }

    // MARK: - Security-scope access (reference-counted per root)

    // Returns the root URL ready for file access, or nil if the root is
    // unresolved. Every beginAccess must be paired with endAccess.
    @discardableResult
    func beginAccess(_ rootID: UUID) -> URL? {
        accessLock.lock(); defer { accessLock.unlock() }
        guard let url = resolvedURLs[rootID] else { return nil }
        let count = accessCounts[rootID, default: 0]
        if count == 0 {
            // false = the URL isn't security-scoped (device-local folder,
            // app's own container) — access works without a grant.
            if url.startAccessingSecurityScopedResource() {
                scopeHeld.insert(rootID)
            }
        }
        accessCounts[rootID] = count + 1
        return url
    }

    func endAccess(_ rootID: UUID) {
        accessLock.lock(); defer { accessLock.unlock() }
        guard let count = accessCounts[rootID], count > 0 else { return }
        accessCounts[rootID] = count - 1
        if count == 1, scopeHeld.remove(rootID) != nil {
            resolvedURLs[rootID]?.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Playback URL resolution

    // Resolve a folder track's playable file URL. The caller
    // (PlaybackEngineService) is responsible for beginAccess/endAccess on
    // the returned rootID across the playback lifetime.
    func audioURL(forTrack id: UInt64) -> (rootID: UUID, url: URL)? {
        guard let track = catalog.track(for: id),
              let rootURL = resolvedURL(for: track.rootID) else { return nil }
        return (track.rootID, rootURL.appending(path: track.relativePath))
    }

    // MARK: - Artwork

    // Raw embedded artwork bytes for an album: first catalog track with a
    // matching albumID, opened under the root's scope, commonKeyArtwork
    // data. Called from ArtworkCache's folder miss path — rasterization,
    // scaling, and both cache tiers live there.
    func artworkData(forAlbum albumID: UInt64) async -> Data? {
        guard let track = catalog.allTracks.first(where: { $0.albumID == albumID }) else {
            return nil
        }
        guard let rootURL = beginAccess(track.rootID) else { return nil }
        defer { endAccess(track.rootID) }

        let asset = AVURLAsset(url: rootURL.appending(path: track.relativePath))
        guard let common = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtwork).first
        else { return nil }
        return try? await item.load(.dataValue)
    }

    // MARK: - Lyrics

    // Embedded unsynced lyrics for a track, opened under the root's scope.
    // MP3 stores these in the ID3 USLT frame; M4A/AAC files (iTunes-style
    // tagging) use the "©lyr" atom instead — checked as a fallback so
    // non-MP3 folder imports aren't silently blank. Called directly by
    // LyricsView for folder-mode tracks, bypassing the synchronous
    // LibrarySource.getLyrics (which needs a security scope + AVAsset
    // metadata load, both of which want to be async) — same dispatch
    // shape as ArtworkCache.artwork's folder branch.
    func lyrics(forTrack id: UInt64) async -> String? {
        guard let track = catalog.track(for: id),
              let rootURL = beginAccess(track.rootID) else { return nil }
        defer { endAccess(track.rootID) }

        let asset = AVURLAsset(url: rootURL.appending(path: track.relativePath))
        let id3 = (try? await asset.loadMetadata(for: .id3Metadata)) ?? []
        if let item = AVMetadataItem.metadataItems(from: id3, filteredByIdentifier: .id3MetadataUnsynchronizedLyric).first,
           let text = try? await item.load(.stringValue), !text.isEmpty {
            return text
        }

        let iTunes = (try? await asset.loadMetadata(for: .iTunesMetadata)) ?? []
        if let item = AVMetadataItem.metadataItems(from: iTunes, filteredByIdentifier: .iTunesMetadataLyrics).first,
           let text = try? await item.load(.stringValue), !text.isEmpty {
            return text
        }

        return nil
    }

    // MARK: - Scanning

    // Full rescan of every root: complete walk + extract each time. A
    // (relativePath, mtime, size) incremental diff remains a deferred
    // optimization (Phase 6+).
    func rescan() {
        guard !isScanning else {
            print("📁 Rescan requested while a scan is running — ignored")
            return
        }
        isScanning = true
        scanProgress = nil
        let rootsSnapshot = roots

        Task.detached(priority: .userInitiated) { [self] in
            var extracted: [FolderTrack] = []
            var playlistFiles: [RawPlaylistFile] = []
            var counts: [UUID: Int] = [:]
            var newlyStale: Set<UUID> = []

            for root in rootsSnapshot {
                // Hold the root's scope for the whole walk + extract pass.
                guard let rootURL = beginAccess(root.id) else {
                    newlyStale.insert(root.id)
                    continue
                }
                defer { endAccess(root.id) }

                let files = FolderTrackScanner.mediaFiles(under: rootURL)
                await MainActor.run {
                    let done = extracted.count
                    self.scanProgress = (discovered: done + files.audio.count, processed: done)
                }

                // Capture playlist bytes now, while the scope is held;
                // parsing + entry resolution happen at catalog build, after
                // track ids are final (collision salting can change them).
                for file in files.playlists {
                    guard let data = try? Data(contentsOf: file.url) else {
                        print("📁 ⚠️ Unreadable playlist file skipped: \(file.relativePath)")
                        continue
                    }
                    playlistFiles.append(RawPlaylistFile(
                        rootID: root.id, relativePath: file.relativePath, data: data
                    ))
                }

                let tracks = await FolderTrackScanner.extractTracks(
                    from: files.audio,
                    rootID: root.id
                ) { processed in
                    Task { @MainActor in
                        if let current = self.scanProgress {
                            self.scanProgress = (current.discovered, min(current.discovered, current.processed + processed))
                        }
                    }
                }
                extracted.append(contentsOf: tracks)
                counts[root.id] = tracks.count
            }

            let data = Self.buildCatalog(from: extracted, playlistFiles: playlistFiles)

            await MainActor.run {
                self.isScanning = false
                self.scanProgress = nil
                self.staleRootIDs.formUnion(newlyStale)
                for index in self.roots.indices {
                    if let count = counts[self.roots[index].id] {
                        self.roots[index].trackCount = count
                        self.roots[index].lastScanCompletedAt = Date()
                    }
                }
                self.saveRoots()
                // Stage only — the live catalog, its disk copy, and the UI
                // pipeline are untouched until loadStagedLibrary().
                self.stagedCatalog = data
                self.stagedTrackCount = data.tracks.count
                print("📁 Scan complete: \(data.tracks.count) tracks, \(data.playlists.count) playlist(s) staged across \(rootsSnapshot.count) root(s) — awaiting Load")
            }
        }
    }

    // The explicit "Load library" action: apply the staged scan result as
    // the live folder library. Erases the queue first (staged content may
    // not contain what's queued), persists the catalog, then announces so
    // LibraryStore / search / views rebuild from it.
    @MainActor
    func loadStagedLibrary() {
        guard let data = stagedCatalog else {
            print("📁 Load requested with nothing staged — ignored")
            return
        }
        AudioPlayerService.shared.stopPlaybackAndEraseQueue()
        catalog.install(data)
        Self.saveCatalog(data)
        stagedCatalog = nil
        stagedTrackCount = nil
        print("📁 Loaded folder library: \(data.tracks.count) tracks live")
        NotificationCenter.default.post(name: .ampLibrarySourceDidChange, object: nil)
    }

    // A playlist file's bytes, captured during the scan while its root's
    // scope was held. Parsed and resolved at catalog build.
    struct RawPlaylistFile {
        let rootID: UUID
        let relativePath: String
        let data: Data
    }

    // Deterministic catalog assembly: sort by (rootID, relativePath) before
    // id-collision handling so salting reproduces identically on every
    // rescan of the same file set, then sort the final list by title (the
    // Songs tab order).
    private static func buildCatalog(
        from tracks: [FolderTrack],
        playlistFiles: [RawPlaylistFile]
    ) -> FolderCatalogData {
        let ordered = tracks.sorted {
            ($0.rootID.uuidString, $0.relativePath) < ($1.rootID.uuidString, $1.relativePath)
        }
        var byID: [UInt64: FolderTrack] = [:]
        byID.reserveCapacity(ordered.count)
        var resolved: [FolderTrack] = []
        resolved.reserveCapacity(ordered.count)

        for track in ordered {
            var candidate = track
            var salt = 0
            while let existing = byID[candidate.song.persistentID],
                  (existing.rootID, existing.relativePath) != (candidate.rootID, candidate.relativePath) {
                salt += 1
                print("📁 ⚠️ Track id collision (\(candidate.relativePath) vs \(existing.relativePath)) — salting (\(salt))")
                let newID = FolderID.track(rootID: track.rootID, relativePath: track.relativePath, salt: salt)
                candidate = FolderTrack(
                    song: Song(
                        persistentID: newID,
                        title: track.song.title,
                        artist: track.song.artist,
                        album: track.song.album,
                        releaseDate: track.song.releaseDate,
                        albumTrackNumber: track.song.albumTrackNumber,
                        discNumber: track.song.discNumber,
                        genre: track.song.genre
                    ),
                    rootID: track.rootID,
                    relativePath: track.relativePath,
                    duration: track.duration,
                    albumArtist: track.albumArtist,
                    albumID: track.albumID,
                    artistID: track.artistID
                )
            }
            byID[candidate.song.persistentID] = candidate
            resolved.append(candidate)
        }

        let byTitle = resolved.sorted { LibraryService.nameOrder($0.song.title, $1.song.title) }
        return FolderCatalogData(
            version: FolderCatalogData.currentVersion,
            tracks: byTitle,
            playlists: buildPlaylists(from: playlistFiles, tracks: resolved)
        )
    }

    // Parse + resolve playlist files against the FINAL track set (ids are
    // post-salting). A playlist whose entries all fail to resolve still
    // appears — empty — rather than vanishing; consistent with decision #7's
    // never-silently-drop stance.
    private static func buildPlaylists(
        from files: [RawPlaylistFile],
        tracks: [FolderTrack]
    ) -> [FolderPlaylist] {
        guard !files.isEmpty else { return [] }

        // Relative entries resolve within the playlist's own root; the
        // filename fallback spans all roots (see M3UParser.resolve).
        var pathsByRoot: [UUID: [String: UInt64]] = [:]
        var filenameCandidates: [String: [M3UParser.TrackCandidate]] = [:]
        for track in tracks {
            let key = M3UParser.normalizeKey(track.relativePath)
            pathsByRoot[track.rootID, default: [:]][key] = track.song.persistentID
            if let filename = key.split(separator: "/").last.map(String.init) {
                filenameCandidates[filename, default: []].append(
                    M3UParser.TrackCandidate(id: track.song.persistentID, normalizedPath: key)
                )
            }
        }

        // Same deterministic order + id-collision salting as tracks.
        let ordered = files.sorted {
            ($0.rootID.uuidString, $0.relativePath) < ($1.rootID.uuidString, $1.relativePath)
        }
        var owners: [UInt64: (UUID, String)] = [:]
        var playlists: [FolderPlaylist] = []
        for file in ordered {
            let path = file.relativePath as NSString
            // .txt is Apple Music's TSV export (own parser); everything
            // else is a real m3u/pls. Both feed the same resolver.
            let entries = path.pathExtension.lowercased() == "txt"
                ? AppleMusicTextPlaylistParser.entries(in: file.data)
                : M3UParser.entries(in: file.data, fileExtension: path.pathExtension)
            let trackIDs = M3UParser.resolve(
                entries: entries,
                playlistDirectory: path.deletingLastPathComponent,
                trackIDsByPath: pathsByRoot[file.rootID] ?? [:],
                filenameCandidates: filenameCandidates
            )
            var salt = 0
            var id = FolderID.playlist(rootID: file.rootID, relativePath: file.relativePath)
            while let owner = owners[id], owner != (file.rootID, file.relativePath) {
                salt += 1
                print("📁 ⚠️ Playlist id collision (\(file.relativePath)) — salting (\(salt))")
                id = FolderID.playlist(rootID: file.rootID, relativePath: file.relativePath, salt: salt)
            }
            owners[id] = (file.rootID, file.relativePath)
            playlists.append(FolderPlaylist(
                id: id,
                name: (path.lastPathComponent as NSString).deletingPathExtension,
                trackIDs: trackIDs
            ))
        }
        return playlists.sorted { LibraryService.nameOrder($0.name, $1.name) }
    }

    // MARK: - Persistence (.atomic — non-negotiable for every amp cache)

    private func loadRoots() {
        guard let data = try? Data(contentsOf: Self.rootsFileURL) else { return }
        do {
            roots = try JSONDecoder().decode([FolderRoot].self, from: data)
            print("📁 Loaded \(roots.count) folder root(s)")
        } catch {
            print("📁 ❌ Roots decode failed: \(error) — starting empty")
        }
    }

    private func saveRoots() {
        let snapshot = roots
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: Self.rootsFileURL, options: .atomic)
            } catch {
                print("📁 ❌ Roots save failed: \(error)")
            }
        }
    }

    private func loadCatalog() {
        guard let data = try? Data(contentsOf: Self.catalogFileURL) else { return }
        do {
            let decoded = try JSONDecoder().decode(FolderCatalogData.self, from: data)
            guard decoded.version == FolderCatalogData.currentVersion else {
                print("📁 Catalog version mismatch (\(decoded.version) vs \(FolderCatalogData.currentVersion)) — discarding")
                return
            }
            catalog.install(decoded)
            print("📁 Loaded folder catalog: \(decoded.tracks.count) tracks")
        } catch {
            print("📁 ❌ Catalog decode failed: \(error) — will rebuild on next scan")
        }
    }

    private static func saveCatalog(_ data: FolderCatalogData) {
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: catalogFileURL, options: .atomic)
            print("📁 Catalog saved (\(encoded.count / 1024)KB)")
        } catch {
            print("📁 ❌ Catalog save failed: \(error)")
        }
    }
}
