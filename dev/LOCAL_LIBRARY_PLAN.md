# Local Folder Music Library — Implementation Plan

## Architectural decision (tradeoff)

**Merge into the same library, not a separate tab.** The app has five services (LibraryService, LibraryStore, SearchIndexService, ArtworkCache, QueueManager) that all key off `MPMediaEntityPersistentID` and `MPMediaItem` today — a separate tab would still need every one of them duplicated to get useful UX (search, albums/artists grouping, queueing across both sources). Merging via a `TrackID` union type lets every view, every cache, and every queue row work uniformly; local tracks appear in Albums/Artists/Songs alongside the Apple Music library. The concrete cost is Phase 1: a refactor touching 17 files. That cost is paid once; the separate-tab path pays it forever.

UX consequence to accept: shuffle "All Songs" will mix sources. That's the right default — users who added folders presumably want them treated as first-class.

## Proposed `Song` / identity shape

```swift
// New canonical track identity. Stable across app launches; Codable for
// every on-disk cache (queue, snapshot, search index, library caches).
enum TrackID: Hashable, Codable {
    case mediaLibrary(MPMediaEntityPersistentID)   // UInt64, existing path
    case localFile(LocalTrackID)                   // new
}

// Stable identity for a file-backed track. UUID is minted on first scan
// and carried across bookmark resolution so the ID survives a folder
// re-resolve (bookmark-stale recovery). Equality is UUID-only; path is
// display / debug metadata.
struct LocalTrackID: Hashable, Codable {
    let uuid: UUID
    let rootID: UUID               // parent FolderRoot
    let relativePath: String       // "Artist/Album/01 Track.mp3", for debug
}

struct Song: Identifiable, Hashable, Codable {
    let id: TrackID                // was: MPMediaEntityPersistentID
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?       // promoted — local files need this explicitly
    let releaseDate: Date?
    let albumTrackNumber: Int
    let discNumber: Int
    let genre: String?
    let duration: TimeInterval?    // new, stored — local scan captures it, MP cache already holds it

    // Migration shim — keep an optional accessor for code that genuinely
    // needs MPMediaItem.persistentID (Now Playing, artwork, LikedTracks
    // while that service is on MP only). Returns nil for local tracks.
    var persistentID: MPMediaEntityPersistentID? {
        if case .mediaLibrary(let id) = id { return id }
        return nil
    }
}

// Root folder the user has granted access to.
struct FolderRoot: Codable, Identifiable {
    let id: UUID
    var displayName: String        // last-path-component at add time
    var bookmarkData: Data         // security-scoped bookmark, Data.init(resolvingBookmarkData:)
    var addedAt: Date
    var lastScanCompletedAt: Date?
    var trackCount: Int
}
```

`Album.id` and `Artist.id` stay `MPMediaEntityPersistentID` for Apple Music, but get a parallel `case local(UUID)` through the same `TrackID`-style enum approach — `AlbumID` / `ArtistID` union types. Local album identity is derived: `sha256(albumArtist + "|" + albumTitle)` truncated to a UUID, so the same album imported from two different folders coalesces rather than duplicating.

---

## Phase 1 — `Song` model refactor (no user-visible change)

**Goal:** land the `TrackID` union and `AlbumID`/`ArtistID` unions, preserving 100% of today's MP-only behavior. Nothing scans files yet. Ships.

**Files to touch (17):**
- `DataModels.swift` — introduce `TrackID`, `AlbumID`, `ArtistID`, update `Song`/`Album`/`Artist`. Add `enum CodingKeys` tombstone for legacy `persistentID` field so old queue/snapshot/cache files still decode.
- `LibraryService.swift` — `song(from: MPMediaItem)` builds `.mediaLibrary` IDs; `getSong(by id: TrackID)`, `getSongs(by: [TrackID])`, `getAudioURL(for: Song)`, `getDuration(forTrack: TrackID)`, `getLyrics(forTrack: TrackID)`.
- `PlaybackEngineService.swift` — `getAudioURL(for:)` (L482) becomes a dispatch: if `.mediaLibrary`, existing MPMediaQuery; if `.localFile`, resolve bookmark → build URL. `getArtwork(for:)` (L498) same.
- `PlaybackQueue.swift` — `trackIDs: [TrackID]`, `originalOrder: [TrackID]`, cache keyed by `TrackID`.
- `QueueManagerService.swift` — all `[MPMediaEntityPersistentID]` → `[TrackID]`; `startPlayback(fromTrackIDs:)` signature change; `saveQueue` uses `TrackID`. `performSnapshotSave` dispatches MP vs local for URL resolution.
- `QueuePersistenceService.swift` — `PersistedQueue.trackIDs: [TrackID]`, `originalOrder: [TrackID]`. Bump `PersistedQueue.version` to 2. Keep v1 decode path that upgrades `[UInt64]` → `[TrackID.mediaLibrary]` on load (see Phase 6 forward-compat).
- `SearchIndexService.swift` — `PersistedSearchIndex` gets `version = 3`; all `[MPMediaEntityPersistentID: X]` caches rekey to `[TrackID: X]`. Word indices map to `Set<TrackID>`. On v2 cache file discovered: discard, rebuild.
- `LibraryStore.swift` — `PersistedArtists.albumCounts` dict key becomes `ArtistID`. Bump each `currentVersion`.
- `ArtworkCache.swift` — key stays `AlbumID`; MP branch unchanged, local branch added (Phase 3).
- `CurrentTrackSnapshot.swift` — bump to v2; `Song` round-trips via new shape. Keep `assetURL` field but make it ignore-on-MP-miss (the URL is stored verbatim so local works too; MP URLs are re-resolved via MPMediaQuery at decode time since `ipod-library://` URLs aren't stable).
- `LikedTracksService.swift` — storage becomes `Set<TrackID>`. UserDefaults key bumped to `amp.likedTrackIDs.v2`; legacy `[NSNumber]` read at init migrates in-place.
- `AudioPlayerService.swift` — signature updates for `startPlayback(fromTrackIDs:)`.
- `NotificationService.swift` — `lastNotificationSongID: TrackID?`.
- All detail views (`AlbumDetailView`, `ArtistDetailView`, `PlaylistDetailView`, `GenreDetailView`, `SearchView`, `LyricsView`, `QueueView`, `NowPlayingView`, `AlbumArtView`, `SongResultRow`, `TrackRow`, `MockLibraryService`) — mechanical `persistentID` → `id` replacements, guarded `.mediaLibrary`-only code paths where they query MP directly.

**Checkpoint:** app builds, all queue/search/playback works for Apple Music library exactly as today. Legacy queue/snapshot files upgrade transparently.

**Effort:** 2–3 days (tedious; compiler drives most of it once the enum is defined).

**Risks:** `Codable` for `TrackID` enum adds a ~5% size tax on queue files (acceptable; binary plist keys short enum values efficiently). `Hashable` parity — make sure `.mediaLibrary(0) != .localFile(...uuidZero...)`; the enum case discriminator handles this. `MPNowPlayingInfoPropertyExternalContentIdentifier` and friends in `MPNowPlayingInfoCenter` take strings — derive `"mp:\(id)"` / `"local:\(uuid)"` for external-ID so Control Center scrubbing/commands identify the track reliably across our two sources.

---

## Phase 2 — Folder picker, bookmarks, flat song list

**Goal:** user can add a folder, app scans it, new tracks appear in a new `Local Files` Library filter chip (flat song list only). MP library untouched. Ships.

**New files:**
- `FolderLibraryService.swift` — manages `[FolderRoot]`, persists to `Application Support/amp/folder_roots.plist`. Resolves bookmarks on launch, tracks stale bookmarks, brackets `startAccessingSecurityScopedResource()` / `stopAccessing...()` around reads. Exposes `async func addFolder(url: URL)`, `removeFolder(id: UUID)`, `allTracks() -> [Song]`, `trackCount(forRoot: UUID) -> Int`.
- `LocalScanService.swift` — bounded-concurrency directory walk using `FileManager.enumerator(at:includingPropertiesForKeys:)`, collects MP3/M4A/AAC/ALAC/FLAC/WAV/AIFF by UTType. Emits progress via `@Published`.
- `LocalMetadataExtractor.swift` — wraps `AVAsset.loadValuesAsynchronously(forKeys: ["commonMetadata", "availableMetadataFormats", "duration"])` with a `TaskGroup` bounded to 6 in flight. Extracts title/artist/album/albumArtist/track/disc/genre/year using existing `parseDateString` in `LibraryService`. Falls back to filename-parsing (`01 Artist - Title.mp3`) when tags absent.
- `LocalTrackCache.swift` — disk-persisted `[LocalTrackID: LocalTrackCacheEntry]` keyed by `(rootID, relativePath)`. Entry holds `(mtime, fileSize, extractedMetadata)`. Lives next to `SearchIndex.cache` in `Caches/LocalTracks.cache`, binary plist, version 1. Incremental rescan strategy: walk, match `(relativePath, mtime, size)` against cache; matches skip extraction, mismatches queue for extraction, missing-from-filesystem entries get tombstoned.
- `FolderLibraryView.swift` (Settings-pushed) — add/remove roots, scan progress, last-scanned timestamp, "unavailable" count per root.
- `ScanProgressBanner.swift` — thin bar at top of Library when scan running.

**Touch:**
- `SettingsView.swift` — "Local Files" row pushes `FolderLibraryView`.
- `LibraryView.swift` — Songs chip includes merged local results. Behind a feature flag (user default) for Phase 2 dogfooding; removed for Phase 3.
- `LibraryService.swift` — `getAllSongs()` returns MP + local. `getSong(by: TrackID)` dispatches.
- `Info.plist` — no new keys needed (`UIFileSharingEnabled` not required for `UIDocumentPickerViewController` folder mode; security-scoped bookmarks don't require a declared entitlement for user-picked folders).

**Security-scoped bookmark flow:**
1. `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])` returns a URL with a scoped-resource token.
2. `startAccessingSecurityScopedResource()` immediately after, then `URL.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)` captures the persistent bookmark. `stopAccessing` after bookmark capture — we don't hold the scope while idle.
3. Persist `bookmarkData` inside `FolderRoot`.
4. On launch: for each root, `URL(resolvingBookmarkData:options:.withoutUI:relativeTo:nil, bookmarkDataIsStale:&stale)`. If `stale`, surface "folder needs re-adding" affordance in `FolderLibraryView` — do not silently re-prompt.
5. Wrap all file reads (scan walk, metadata extract, `AVAudioFile` open) with a `FolderRoot.withAccess { url in ... }` helper that does `startAccessing`, runs the block, `stopAccessing` in `defer`. **Playback** holds the scope for the lifetime of the `AVAudioFile` — `startAccessing` before `AVAudioFile(forReading:)`, `stopAccessing` in `PlaybackEngineService.cleanupAudioResources*` and `stop()`.

**Checkpoint:** user can add a folder, see progress, scan finishes, local tracks playable from an all-songs list. No album/artist grouping yet (Phase 3).

**Effort:** 3–4 days.

**Risks:**
- **iCloud Drive placeholders:** `.icloud` sidecar files (hidden, zero-byte on-disk) appear in enumerate output. Either pre-filter via `URLResourceValues.isUbiquitousItem` + `.ubiquitousItemDownloadingStatusKey`, or let the extractor call `FileManager.default.startDownloadingUbiquitousItem(at:)` + poll download status before opening. Handled properly in Phase 4.
- **Bookmark stale:** iOS has tightened bookmark invalidation in iOS 17+; treat staleness as normal operational state, not exceptional.

---

## Phase 3 — Merge into Albums / Artists / Search

**Goal:** local tracks appear grouped by album and artist, searchable, queueable interleaved with MP tracks. Ships.

**Touch:**
- `LibraryService.swift` — `getAllAlbums()`, `getAllArtists()`, `getAllArtistsWithAlbumCounts()`, `getAlbums(forArtist:)`, `getSongs(forAlbum:)` all merge MP + local sources. Local album/artist IDs derived deterministically (see model shape above) so re-scans don't churn UUIDs.
- `LibraryStore.swift` — `libraryDidChange` fires from both `MPMediaLibraryDidChange` (existing) AND a new `NSNotification.Name("AmpLocalLibraryDidChange")` posted by `FolderLibraryService` after scans. Cache versioning: bump all four tab caches (they now carry the local-merged data, old caches invalid).
- `SearchIndexService.swift` — during `buildIndex`, pull local songs from `FolderLibraryService.allTracks()` after the MP pass. The key change: `libraryDidChange` must listen to both sources (same as LibraryStore). Version bumps to 4.
- `ArtworkCache.swift` — artwork dispatch: `.mediaLibrary(id)` path unchanged; `.local(uuid)` path reads `AVAsset.commonMetadata` type `.artwork` (data payload), rasterizes, caches under the same disk layout keyed by `AlbumID` hash. Same JPEG-at-0.8, same invalidation marker extended to include local-library-mtime.
- `AlbumDetailView.swift`, `ArtistDetailView.swift`, `SearchView.swift`, `PlaylistDetailView.swift`, `GenreDetailView.swift` — no logic changes if IDs are union type; mechanical adjustments for code that was pattern-matching on `MPMediaEntityPersistentID` directly.
- `NotificationService.swift` — `lastNotificationSongID` check works on `TrackID` equality.

**Checkpoint:** a user's 5k-song Apple Music library + 2k-track Dropbox folder show up unified. Search hits both. Queueing across sources works.

**Effort:** 2–3 days.

**Risks:**
- **Artist identity collision:** deterministic local artist ID = hash of name. If the MP library has "Radiohead" and a local folder has "Radiohead", they'll appear as two rows unless we also collapse across-source artist matches. Decision: don't collapse in Phase 3 (keep it simple; show both). Phase 5 polish can add a "merge by name" heuristic if users complain.
- **Artwork perf:** rasterizing artwork from AVAsset is slower than MP's pre-rasterized `artwork.image(at:)`. The existing NSCache + disk JPEG cache amortizes this; cold-scroll-through-2000-local-albums pays a one-time hit. Disk cache invalidation keyed off `max(MP.lastModified, Local.lastModified)` in the marker file.

---

## Phase 4 — iCloud Drive and file-provider correctness

**Goal:** `.icloud` placeholders and Dropbox/Google Drive "download-on-demand" files play correctly without surprise UX. Ships.

**Implementation:** a new `ResolvedAudioURL.resolve(for: Song) async throws -> URL` helper, called by `PlaybackEngineService.getAudioURL(for:)` and `LocalMetadataExtractor.openAsset`. For local-file URLs:

1. Read `URLResourceValues.isUbiquitousItem`, `.ubiquitousItemDownloadingStatusKey`, `.ubiquitousItemIsDownloadingKey`.
2. If not ubiquitous, return URL directly (most file-provider cases — Dropbox presents non-ubiquitous URLs for downloaded files).
3. If ubiquitous and `.current`, return URL.
4. If ubiquitous and `.notDownloaded` or `.downloaded` (stale): call `FileManager.default.startDownloadingUbiquitousItem(at:)`, then wrap the open in `NSFileCoordinator().coordinate(readingItemAt: options: .withoutChanges) { coordinatedURL in ... }`. Poll `.ubiquitousItemIsDownloadingKey` with `Task.sleep(100ms)` up to a 30s timeout. Show a brief "Downloading…" state in `NowPlayingView` while waiting (surface via `@Published var isDownloadingTrack: Bool` on `PlaybackEngineService`).
5. If download fails: `delegate?.playbackDidFinish(successfully: false)` — same recovery path as corrupt-file, advances to next track.

**Touch:**
- `PlaybackEngineService.swift` — `getAudioURL` becomes async (or uses a completion). Cascades upward: `play(song:)` becomes `async` OR wraps in `Task` with a "loading" guard to block re-entry. Cleanest approach: add `func play(song: Song, isManualSelection: Bool = false) { Task { await self.playAsync(song:...) } }` and do the real work async internally; existing callers' sync signatures stay valid.
- `LocalMetadataExtractor.swift` — same helper for scan-time file opens.
- `NowPlayingView.swift` — show download-spinner state.

**Checkpoint:** a track living only in iCloud can be tapped from a fresh device and plays after download.

**Effort:** 1.5 days.

**Risks:** `NSFileCoordinator` adds latency; scrubbing a queue through 10 iCloud tracks back-to-back is visibly slow. Acceptable for v1 — add a background prefetch for "next track in queue" in a later phase.

---

## Phase 5 — Background scan, incremental rescan, manual trigger

**Goal:** scanning is never a "wait 5 minutes at first launch" UX. Ships.

**Implementation:**
- `LocalScanService` runs as `TaskGroup` with `maxConcurrent = 6` (tunable, roughly matches A-series iPhone's efficiency cores + 2 for I/O overlap). `AVAsset.loadValuesAsynchronously(forKeys:)` on each file; batch 200 files, commit to `LocalTrackCache` per batch (so a kill mid-scan loses at most 200 tracks of work).
- Scan triggers: (a) after `FolderLibraryService.addFolder`, (b) manual "Rescan" button in `FolderLibraryView`, (c) on app launch if `lastScanCompletedAt` > 24h old, runs after a 2s idle delay so it doesn't compete with `LibraryStore.ensure*` + `SearchIndexService.buildIndex` for the cold-launch CPU budget.
- Incremental rescan: walk filesystem, diff against cache by `(relativePath, mtime, size)`. Only extract metadata for changed/new files. Delete tombstoned entries. On typical "nothing changed" rescan of 2000 files, total work is the directory walk (~200ms) plus cache compare (microseconds). No AVAsset opens.
- Progress: `@Published var scanProgress: (rootID: UUID, discovered: Int, processed: Int)?` on `FolderLibraryService`. `ScanProgressBanner` binds, fades out on `nil`.

**Touch:** `LocalScanService.swift` (flesh out bounded concurrency), `LocalTrackCache.swift` (incremental diff logic), `FolderLibraryService.swift` (triggers + progress).

**Checkpoint:** second-launch scan of an unchanged 2000-track folder is ~250ms.

**Effort:** 1.5 days.

**Risks:** `AVAsset` on ALAC files in m4a containers is reliable; on FLAC it only works on iOS 15+ with the `AVURLAsset` path (older iOS versions need third-party decode, which is out of scope — **document FLAC as iOS 15+ only**, show a warning banner on older devices when a FLAC is in a folder). WAV/AIFF need explicit UTType checks; AVFoundation handles them natively.

**Format matrix (explicit):**
- MP3, M4A (AAC and ALAC), WAV, AIFF: full support, all iOS targets.
- FLAC: iOS 15+ only, via `AVURLAsset`. On iOS 14 and below, show a per-track "unsupported format" badge instead of skipping silently.
- OGG Vorbis / Opus: out of scope for v1 (no native iOS decoder). Filter at scan.
- Artwork: embedded via ID3 APIC / iTunes `covr` / Vorbis METADATA_BLOCK_PICTURE — `AVAsset.commonMetadata` with `commonKey == .commonKeyArtwork` works for the first two. FLAC artwork extraction needs manual METADATA_BLOCK_PICTURE parse; defer to Phase 6 polish.

---

## Phase 6 — Queue persistence forward-compat + hardening

**Goal:** v1-of-app queue files open cleanly in v2-of-app. "Track not available" queue rows render sensibly. Ships.

**Already designed into Phase 1**, expanded here:

- `PersistedQueue.version` bump 1 → 2. Decode path: if `version == 1`, read `[UInt64]` from the legacy plist shape, map each to `.mediaLibrary(id)`. `QueueBinaryCoder.decode` gains a pre-check that inspects the first bytes of the plist to route to legacy vs current.
- `CurrentTrackSnapshot.version` bump 1 → 2: legacy v1 snapshot only held `persistentID` (in `song.persistentID`), so v2 decoder wraps into `.mediaLibrary`.
- **Unavailable track handling:** `QueueView` already filters out tracks that `LibraryService.getSong(by:)` can't resolve. Extend: if `.localFile` ID's bookmark is stale, show the row with a "⚠ folder unavailable" badge and disable the play tap. Removing it from the queue is a user action (swipe), not automatic — otherwise a temporary iCloud Drive disconnect would nuke queue entries.
- `LikedTracksService` — legacy `Set<UInt64>` on disk migrates to `Set<TrackID>` on next write.

**Touch:** `QueuePersistenceService.swift`, `CurrentTrackSnapshot.swift`, `QueueView.swift`, `QueueRow` (the row component inside QueueView).

**Checkpoint:** install v2 over v1, queue restores, liked tracks preserved, nothing lost.

**Effort:** 1 day.

**Risks:** legacy decode fallback must be tested with a real v1-generated queue file; recommend committing a fixture file under `ampTests/Fixtures/legacy_queue_v1.plist` and a round-trip test.

---

## Total effort and sequencing

| Phase | Effort | Blocker for |
|---|---|---|
| 1. Model refactor | 2–3d | everything |
| 2. Folder picker + flat list | 3–4d | 3, 4 |
| 3. Merge into Library/Search | 2–3d | — |
| 4. iCloud / file-provider correctness | 1.5d | — |
| 5. Background + incremental scan | 1.5d | — |
| 6. Queue persistence forward-compat | 1d | can overlap with 1 |

**Total: 11–15 days.** Phases 3/4/5/6 are parallelizable once 1 and 2 land.

## Explicit watch-out list

- Every disk cache in this project (search index, queue, snapshot, library store, artwork thumbnails) uses `.atomic` writes. The rule is non-negotiable — new caches (`folder_roots.plist`, `LocalTracks.cache`) must too.
- `MPMediaLibraryDidChange` notifications only fire for the MP library. The local-library invalidation notification must post from `FolderLibraryService.addFolder` / `removeFolder` / scan-complete. `LibraryStore` and `SearchIndexService` listen to both.
- `MPMediaQuery` calls inside `QueueManagerService.performSnapshotSave` and `PlaybackEngineService.getAudioURL` / `getArtwork` — each needs the dispatch on TrackID.
- `MockLibraryService` (DEBUG only) needs a parallel mock local path so DEBUG builds don't break when the Song shape changes.
- Permission: `UIDocumentPickerViewController(forOpeningContentTypes:)` does NOT require an Info.plist usage key for folder-picker flow.

### Critical files for implementation
- `/Users/zen/dev/src/amp/amp/amp/DataModels.swift`
- `/Users/zen/dev/src/amp/amp/amp/LibraryService.swift`
- `/Users/zen/dev/src/amp/amp/amp/PlaybackEngineService.swift`
- `/Users/zen/dev/src/amp/amp/amp/QueueManagerService.swift`
- `/Users/zen/dev/src/amp/amp/amp/SearchIndexService.swift`
