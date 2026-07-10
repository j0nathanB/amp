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

// The persisted, derived catalog — what a warm launch loads instead of
// re-reading AVAsset tags. tracks are pre-sorted by title (the Songs tab
// order) at build time.
struct FolderCatalogData: Codable {
    let version: Int
    let tracks: [FolderTrack]

    static let currentVersion = 1
    static let empty = FolderCatalogData(version: currentVersion, tracks: [])
}

// Thread-safe in-memory catalog snapshot. LibrarySource methods are
// synchronous and get called from detached tasks (LibraryStore rebuilds)
// as well as the main thread, so reads must not require an actor hop —
// same reasoning as HybridSearchIndex's queue-guarded caches.
final class FolderCatalog {
    private let lock = NSLock()
    private var songsByTitle: [Song] = []
    private var byID: [UInt64: FolderTrack] = [:]

    func install(_ data: FolderCatalogData) {
        var index: [UInt64: FolderTrack] = [:]
        index.reserveCapacity(data.tracks.count)
        for track in data.tracks { index[track.song.persistentID] = track }
        lock.lock()
        songsByTitle = data.tracks.map { $0.song }
        byID = index
        lock.unlock()
    }

    var allSongs: [Song] {
        lock.lock(); defer { lock.unlock() }
        return songsByTitle
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
}

// MARK: - Service

final class FolderLibraryService: ObservableObject {
    static let shared = FolderLibraryService()

    // Main-thread published state for FolderSettingsView.
    @Published private(set) var roots: [FolderRoot] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: (discovered: Int, processed: Int)?
    @Published private(set) var staleRootIDs: Set<UUID> = []

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

    // MARK: - Scanning

    // Full rescan of every root. Phase 3 is a complete walk + extract each
    // time; Phase 5 adds the (relativePath, mtime, size) incremental diff.
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
            var counts: [UUID: Int] = [:]
            var newlyStale: Set<UUID> = []

            for root in rootsSnapshot {
                // Hold the root's scope for the whole walk + extract pass.
                guard let rootURL = beginAccess(root.id) else {
                    newlyStale.insert(root.id)
                    continue
                }
                defer { endAccess(root.id) }

                let files = FolderTrackScanner.audioFiles(under: rootURL)
                await MainActor.run {
                    let done = extracted.count
                    self.scanProgress = (discovered: done + files.count, processed: done)
                }

                let tracks = await FolderTrackScanner.extractTracks(
                    from: files,
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

            let data = Self.buildCatalog(from: extracted)
            catalog.install(data)
            Self.saveCatalog(data)

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
                print("📁 Scan complete: \(data.tracks.count) tracks across \(rootsSnapshot.count) root(s)")
                // Only poke the UI pipeline if folder mode is what's on
                // screen; in music mode the catalog just sits ready.
                if LibraryModeService.shared.mode == .folder {
                    NotificationCenter.default.post(name: .ampLibrarySourceDidChange, object: nil)
                }
            }
        }
    }

    // Deterministic catalog assembly: sort by (rootID, relativePath) before
    // id-collision handling so salting reproduces identically on every
    // rescan of the same file set, then sort the final list by title (the
    // Songs tab order).
    private static func buildCatalog(from tracks: [FolderTrack]) -> FolderCatalogData {
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
        return FolderCatalogData(version: FolderCatalogData.currentVersion, tracks: byTitle)
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
