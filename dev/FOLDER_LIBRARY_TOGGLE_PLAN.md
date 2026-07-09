# Library Source Toggle (Apple Music ⇄ Custom Folders) — Implementation Plan

**Status:** planning — reviewed & amended 2026-07-08 (ArtworkCache dispatch +
key namespacing added; snapshot restore replaced with clear-on-toggle; double-play
fix promoted to Phase 0 prerequisite; testing strategy added).
Supersedes the *merge* approach in `LOCAL_LIBRARY_PLAN.md` for
this direction. That plan's core bet (unify local files *into* the Apple Music
library via a `TrackID` union across 17 files) is **not** what we're building —
we're building a mutually-exclusive source toggle, which is a much smaller change.
Keep `LOCAL_LIBRARY_PLAN.md` around only as a reference for the folder-scan /
bookmark / iCloud mechanics (Phases 2/4/5 there are still directly reusable).

## Locked decisions (from planning Q&A, 2026-07-08)

1. **Exclusive toggle**, not merge. Exactly one source is active at a time. In
   folder mode the Apple Music library is hidden *everywhere* (Songs / Albums /
   Artists / Search / Playlists). Toggle lives in Settings.
2. **Multiple folder roots** (add/remove list). Single-folder is just a list of
   one. Each root is traversed recursively.
3. **Playlists come from `.m3u` / `.pls` files** found in the roots. A raw
   directory has no native playlist concept; subfolders are *not* playlists.
4. **Album/Artist grouping from embedded tags**, filename fallback when tags are
   absent. Folder structure is *not* used for grouping.
5. **Liked tracks and the search index are scoped per-source.** Switching to
   folder mode shows folder likes only; switching back restores Music likes. Each
   source keeps its own set; neither is destroyed by the other.
   *(Amended 2026-07-08: the Now-Playing snapshot is NOT per-source — see #6.
   A per-mode snapshot restore would revive a current track over an erased queue,
   a state the app has never been in and one adjacent to the documented
   ghost-queue restore races. Snapshots are cleared on toggle instead.)*
6. **On toggle: erase the queue, stop playback entirely, and clear BOTH modes'
   Now-Playing snapshots.** Now Playing clears and stays clear after switching
   back. No track from the old source lingers over the new library, and no
   snapshot ever restores a current track that has no backing queue.
7. **Unavailable folder → stay in folder mode, show empty + re-pick.** A stale
   security-scoped bookmark / moved / offline root does not silently dump the
   user's choice; it surfaces a "folder unavailable — re-select" affordance.
8. **Formats:** MP3, M4A (AAC + ALAC), WAV, AIFF, **and FLAC** (FLAC is iOS 15+
   via `AVURLAsset`; FLAC embedded-artwork extraction may lag — see risks).
   OGG/Opus out of scope (no native iOS decoder).
9. **First toggle with no folder chosen → immediately open the system folder
   picker.** Cancelling the picker reverts the toggle to MUSIC.

---

## Central architectural decision: no `TrackID` union — synthesize stable `UInt64` ids

The merge plan needed a `TrackID` enum because Apple Music and local tracks had to
coexist in the same lists, caches, and queue. **Exclusivity removes that
requirement.** At any instant every live `Song`/`Album`/`Artist` comes from one
source, and switching sources reloads every view from scratch. So we can keep the
model *exactly as it is today* (`Song.persistentID: MPMediaEntityPersistentID`,
`Album.id`/`Artist.id`/`Playlist.id: UInt64`) and, in folder mode, **synthesize
deterministic `UInt64` ids for local tracks/albums/artists.**

Why this works and is safe:

- `Album` already compares by `title`, `Artist` by `name` (see `DataModels.swift`
  L45–58). Grouping doesn't depend on the numeric id being a real persistentID.
- The synthetic id must be **stable across launches** and therefore cannot use
  Swift's per-run-seeded `Hasher`. Use a fixed hash: **FNV-1a 64-bit** (or
  SHA-256 truncated to 64 bits) over a canonical string:
  - Track id: `fnv1a64("\(rootUUID)|\(relativePath)")`
  - Album id: `fnv1a64("album|\(albumArtist ?? artist)|\(albumTitle)")`
  - Artist id: `fnv1a64("artist|\(artistName)")`
  Deterministic ⇒ re-scans don't churn ids ⇒ queue/liked/snapshot survive rescans.
- **Collision risk:** 64-bit space, personal libraries are 10³–10⁴ tracks →
  birthday-collision probability is ~10⁻¹¹. Acceptable, but the folder track map
  MUST detect a collision on insert (two distinct paths → same id) and, if it ever
  happens, salt with a disambiguator. Cheap guard, documents the assumption.
- Because ids never coexist across sources, a synthetic id in a Music-mode cache
  (or vice-versa) is impossible *as long as every persisted store is scoped per
  source* (below). This is the one invariant the whole design leans on — and it
  applies to **every** keyed store, explicitly including `ArtworkCache`'s NSCache
  and disk thumbnails (see below; the original draft missed it).

**Net effect:** `DataModels.swift` is untouched. No mechanical `persistentID → id`
sweep across 15 views. The change concentrates in a new source-abstraction seam
plus dispatch at exactly two MediaPlayer-coupled points (URL + artwork
resolution).

### The seam: `LibrarySource`

Introduce a protocol that captures what `LibraryService` exposes today, with two
implementations:

```swift
protocol LibrarySource {
    func getAllSongs() -> [Song]
    func getAllAlbums() -> [Album]
    func getAllArtists() -> [Artist]        // + WithAlbumCounts variant
    func getAlbums(forArtist: UInt64) -> [Album]
    func getSongs(forAlbum: UInt64) -> [Song]
    func getSongs(forArtist: UInt64) -> [Song]
    func getPlaylists() -> [Playlist]
    func getPlaylistDetail(for: UInt64) -> PlaylistDetail?
    func getSong(by id: UInt64) -> Song?
    func getSongs(by ids: [UInt64]) -> [Song]
    func audioURL(for song: Song) async -> URL?     // NEW: source resolves its own URL
    func artwork(for song: Song) -> UIImage?         // or the existing artwork path
    // genres, songIDs(forPlaylist:), etc. — mirror current LibraryService surface
}
```

- `MusicLibrarySource` — the *existing* `LibraryService` MPMediaQuery code, moved
  behind the protocol essentially verbatim. `audioURL(for:)` = today's
  `getAudioURL` (predicate → `MPMediaItem.assetURL`).
- `FolderLibrarySource` — new. Backed by the folder scan cache; `audioURL(for:)`
  resolves synthetic id → `(root, relativePath)` → security-scoped file URL.

`LibraryService` becomes a thin front that forwards to `activeSource`, chosen by
`LibraryModeService` (the toggle owner). This keeps every existing caller
(`LibraryView`, detail views, `SearchIndexService`, `QueueManagerService`)
source-agnostic.

---

## New components

- **`LibraryModeService.swift`** — owns `@AppStorage("libraryMode")` (`.music` /
  `.folder`), owns the active `LibrarySource`, and drives the switch sequence
  (stop playback, erase queue, swap per-source stores, kick reload). Posts a
  single `AmpLibrarySourceDidChange` notification that `LibraryStore` and
  `SearchIndexService` already-style listeners subscribe to (alongside
  `MPMediaLibraryDidChange`).
- **`FolderRootStore.swift`** — persists `[FolderRoot]` to
  `Application Support/amp/folder_roots.plist` (**`.atomic`**). Holds
  security-scoped bookmarks, resolves them on launch, tracks staleness, and
  vends a `withAccess { url in … }` bracket (`startAccessingSecurityScopedResource`
  → block → `stopAccessing` in `defer`).
- **`FolderScanService.swift`** — bounded-concurrency recursive walk
  (`FileManager.enumerator`), `maxConcurrent ≈ 6`, filters by `UTType`
  (mp3/m4a/wav/aiff/flac), pulls tags via `AVAsset` common metadata with filename
  fallback, and parses any `.m3u`/`.pls` into `Playlist`s. Emits `@Published`
  progress. (Mechanics lift directly from `LOCAL_LIBRARY_PLAN.md` Phases 2/5.)
- **`FolderLibraryCache.swift`** — disk-persisted, **derived** representation:
  the finished Songs/Albums/Artists/Playlists *and their grouping/sectioning*,
  not the raw file list. (Per project rule: persist derived structures so a warm
  launch skips the rebuild, not just the file walk. See memory
  `project_library_perf_backlog`.) Binary plist, versioned, **`.atomic`**, in
  Application Support (not Caches — see `project_playlist_list_slow_cache_invalidation`).
- **`FolderLibrarySource.swift`** — the `LibrarySource` impl reading from the
  cache and resolving audio URLs through `FolderRootStore.withAccess`.
- **`FolderSettingsView.swift`** — the add/remove roots list, scan progress,
  per-root track count + "unavailable" state, "Rescan" button.
- **`M3UParser.swift`** — parse `.m3u`/`.m3u8`/`.pls`; resolve entry paths
  (relative to the playlist file, and absolute) against scanned tracks by
  normalized path; unresolved entries are dropped (or shown greyed — TBD in UI).

## Existing files touched

- **`SettingsView.swift`** — add a `BrutalistToggle`-style MUSIC/FOLDER control
  (non-invertible, like the TOP/BOTTOM miniplayer toggle) + a "Custom folders"
  row that pushes `FolderSettingsView`. First flip to FOLDER with zero roots →
  open the folder picker immediately; cancel → revert to MUSIC.
- **`LibraryService.swift`** — extract the MPMediaQuery bodies into
  `MusicLibrarySource`; make `LibraryService` forward to `activeSource`. This is
  the bulk of the mechanical work, but it's *move*, not *rewrite*.
- **`ArtworkCache.swift`** — **critical, missed in the first draft.** Four views
  call `ArtworkCache.shared` *directly*, bypassing `LibraryService`
  (`AlbumArtView.swift:246`, `ArtistDetailView.swift:224`, `LibraryView.swift:619`,
  `PlaylistDetailView.swift:238`), and the cache runs its own
  `MPMediaQuery.albums()` internally (`ArtworkCache.swift:129`). Without changes,
  folder mode shows placeholder art in every album/artist/playlist cell. Two fixes:
  1. The miss path dispatches per active source: MP branch = today's query; folder
     branch = resolve album → any member track → `AVAsset` common-metadata artwork
     (`commonKeyArtwork`), rasterize, same JPEG-at-0.8 disk layout.
  2. **Namespace keys by mode** — NSCache and disk filenames become
     `m:{albumID}@{WxH}.jpg` / `f:{albumID}@{WxH}.jpg`. Without this, a synthetic
     folder album id colliding with a real MP album id serves wrong artwork
     across modes, violating the per-source-store invariant.
- **`PlaybackEngineService.swift`** — `getAudioURL(for:)` (L382) and
  `getArtwork(for:)` (L398) dispatch to `activeSource.audioURL/artwork`. For
  folder tracks, **hold the security scope for the playback lifetime** of the item
  (start before load, stop in `cleanupAudioResources*`/`stop()`), mirroring the
  bookmark bracket rule. `getAudioURL` likely needs to become `async` (or
  `Task`-wrapped with a load guard) for iCloud/on-demand roots — same cascade the
  merge plan's Phase 4 described.
- **`LikedTracksService.swift`** — namespace storage by mode:
  `amp.likedTrackIDs.music` / `amp.likedTrackIDs.folder`. Active set follows
  `LibraryModeService`. Export-as-m3u still works per active source.
- **`CurrentTrackSnapshot.swift`** — *(amended)* NOT per-mode. The snapshot is
  refreshed whenever the queue saves (`QueueManagerService.swift:404-407`) and
  its eager-restore path populates `currentTrack` — restoring it over an erased
  queue would create a current-track-with-no-queue state adjacent to the
  documented ghost-queue races. Instead: **the toggle calls
  `CurrentTrackSnapshot.removeFromDisk()`** (both directions). Within folder
  mode, snapshots work normally but store the resolvable `(rootUUID,
  relativePath)`, not an `ipod-library://` URL — version bump gates the shape
  change.
- **`SearchIndexService.swift`** — index the active source; keep a per-mode cache
  file so switching back doesn't force a rebuild. Listen to
  `AmpLibrarySourceDidChange` in addition to `MPMediaLibraryDidChange`.
- **`LibraryStore.swift`** — its four tab caches become **per-mode, firmly** —
  invalidate-on-switch is rejected: it would make every toggle a full rebuild
  storm, the exact failure mode from the library-slow-after-idle postmortem.
  Listens to `AmpLibrarySourceDidChange`.
- **`QueueManagerService.swift`** — expose an `eraseQueue()` the toggle calls;
  queue persistence file effectively resets on switch (decision #6). No union
  needed since ids are already `UInt64`.
- **`MockLibraryService.swift`** — provide a mock `FolderLibrarySource` for DEBUG
  so the picker/list render without real files.

---

## Switch sequence (decision #6, #9)

```
user flips toggle to FOLDER:
  if roots.isEmpty:
      present folder picker
      on cancel: revert toggle to MUSIC; return
      on pick: capture bookmark, add root, continue
  playbackEngine.stop()            // full stop, not pause
  queueManager.eraseQueue()        // clears upcoming + current
  CurrentTrackSnapshot.removeFromDisk()  // both modes' snapshots — no restore
  nowPlaying = nil
  likedTracks.activeMode = .folder
  searchIndex.activeMode = .folder
  libraryMode = .folder            // persisted
  post AmpLibrarySourceDidChange   // views reload from FolderLibrarySource
  if folder cache cold: kick scan (progress banner)
```

Switching back to MUSIC is the mirror image (no scan). Both directions are
idempotent and re-entrancy-guarded (respect the existing transitionState / manual-
start patterns in the playback services).

## Unavailable-folder handling (decision #7)

On launch in folder mode: resolve each root's bookmark. If *all* roots are stale/
missing → folder mode with an **empty library** + a banner "Custom folder
unavailable — re-select" that opens `FolderSettingsView`. Do **not** auto-revert
to Music (that would silently discard the user's chosen mode). Individual stale
roots are shown with a ⚠ badge in the roots list; their tracks are simply absent
from this session's library until re-added.

---

## Watch-outs (project rules — non-negotiable)

- **Every new disk write uses `.atomic`** — `folder_roots.plist`, the folder
  library cache, per-mode liked/snapshot/search caches. (memory:
  `feedback_atomic_writes_non_negotiable`)
- **Persist derived structures, not raw data** — the folder cache stores the
  finished grouped/sectioned Songs/Albums/Artists/Playlists so warm launch skips
  the rebuild, not just the walk. (memory: `project_library_perf_backlog`)
- **Caches live in Application Support, not `Caches/`** — iOS purges `Caches/`
  over long idle; that's the root cause behind
  `project_playlist_list_slow_cache_invalidation`. Invalidate by content
  signature (root set + max mtime), not by `lastModifiedDate`.
- **Synthetic ids must use a fixed hash**, never `Hasher()` — per-run seeding would
  invalidate persisted queue/liked/snapshot on every launch.
- **Hold the security scope across playback**, release deterministically in the
  same cleanup paths that already tear down audio resources.
- **Security scopes must be reference-counted per root, not naively paired.**
  Playback holds a root's scope for a track's lifetime while scan/metadata reads
  bracket the *same* root URL; a naive `start`/`stop` pair means a scan finishing
  tears down playback's scope mid-track. `FolderRootStore` keeps a per-root
  access count; `stopAccessing` fires only at zero.

## Prerequisite: queue double-play bug — RESOLVED (verified 2026-07-08)

The 2x-advance-on-unplayable-track bug was **already fixed** in `2dfbb36`
(2026-05-01), per `dev/PLAYBACK_REVERT_PLAN.md`: wrappers no longer call
`playbackEngine.play` directly; `currentTrackDidChange` is the single play
decision point driven by a `pendingUserAction` enum; recovery is
direction-aware; `handleLoadFailure` caps cascades at 5 consecutive failures
and already handles both failure shapes folder mode will produce (nil URL,
AVAudioPlayer throw). Verified by code trace of both failure scenarios — each
lands exactly one position past a broken track.

**Owed:** one runtime sanity check (prev/next through a real unplayable track
advances exactly 1) the first time folder mode produces one — stale bookmark or
deleted file. Note: do NOT reach for an AVPlayer fallback in unplayable-track
handling — tested and refuted 2026-04-30 (AVPlayer fails identically with
AVErrorUnknown -11800).

## Testing strategy (minimum bar)

- **Synthetic id stability:** FNV-1a fixture test — known `(rootUUID,
  relativePath)` inputs → pinned expected `UInt64`s. Guards against anyone
  "simplifying" to `Hasher()` (per-run seed would invalidate all persisted state).
- **Collision guard:** unit test that the folder track map detects two paths
  mapping to one id and salts.
- **M3U/PLS parser fixtures:** relative paths, absolute paths, `#EXTINF`
  comments, CRLF, UTF-8/Latin-1, entries pointing outside granted roots.
- **Mode-switch state test:** toggle → assert queue empty, playback stopped,
  snapshot files gone, liked set swapped, correct source answering
  `getAllSongs()`. Round-trip back to Music → Music likes intact.
- **ArtworkCache namespacing:** same numeric id in both namespaces returns
  distinct images.
- **Scan cache round-trip:** derived-structure cache decode equals freshly built
  structures for a fixture folder tree.

## Phasing

| Phase | Scope | Effort |
|---|---|---|
| 0. Double-play bug fix (prerequisite) | ✅ **DONE 2026-07-08 — already fixed in `2dfbb36` (2026-05-01)**, per `PLAYBACK_REVERT_PLAN.md`: single play path via `pendingUserAction` + `currentTrackDidChange`, direction-aware recovery, 5-failure cascade cap. Code-trace verified; runtime sanity check owed when folder mode first yields a real unplayable track. | 0d |
| 1. `LibrarySource` seam | ✅ **DONE 2026-07-08.** `LibrarySource` protocol (22 methods, UInt64-keyed) + `MusicLibrarySource` (Release MP bodies verbatim) + `MockLibrarySource` adapter (replaces all per-method `#if DEBUG` branches — parity preserved incl. unsorted mock artists). Index-first shortcuts stayed in `LibraryService`. `getMediaItems`/`song(from:)`/search/enrichment untouched. Both configs build; tests pass. LibraryService −372 lines. | done |
| 2. Toggle + mode plumbing | `LibraryModeService`, Settings toggle, per-mode liked/search, snapshot clear, queue-erase/stop. Folder source stubbed empty. | 1.5d |
| 3. Folder pick + scan + flat songs | `FolderRootStore`, bookmarks, `FolderScanService`, `FolderLibraryCache`, songs list playable. | 3–4d |
| 4. Albums / Artists / Search / Artwork in folder mode | tag grouping + filename fallback, folder search index, `ArtworkCache` per-source dispatch + mode-namespaced keys. | 2–3d |
| 5. Playlists (`.m3u`/`.pls`) | `M3UParser`, playlist detail. | 1d |
| 6. iCloud/on-demand + FLAC hardening + unavailable-root UX | `async` URL resolve, download-wait, FLAC artwork caveat, stale-root banner. | 2d |

**Total ≈ 12–14.5 days**, but Phase 1 ships independently and de-risks the rest.
Phases 4/5/6 parallelize once 3 lands; Phase 0 parallelizes with 1–2.

## Open risks / to-confirm during build

- `getAudioURL` going `async` cascades into `play(song:)`. Cleanest: keep sync
  public signature, do the resolve inside a `Task` with a load guard (mirror the
  merge plan's Phase 4 note).
- FLAC: playback + tag read work on iOS 15+ via `AVURLAsset`; **embedded artwork**
  via `METADATA_BLOCK_PICTURE` may need a manual parse — acceptable to ship FLAC
  with a placeholder cover in v1 and note it.
- `.m3u` path resolution across security-scoped roots: entries may point outside
  any granted root → unresolvable by design; decide drop vs. grey-out in UI.
- Export-liked-as-m3u already exists in Settings — confirm it targets the *active*
  source's liked set and that folder-mode m3u uses real file paths (portable),
  which is actually nicer than the Music-mode `ipod-library://` case.
```
