# Perf plan: queue + playlist loading (2026-06-09)

Source: perf review of queue restore/save and playlist list/detail paths.
Baselines referenced below are the 2026-04-17/18 on-device measurements
(iPhone 13 Pro, 23,792 songs) — do not re-profile, they're authoritative.

> **Status 2026-06-09:** items 1-4 below all IMPLEMENTED. Release + Debug
> builds green, ampTests green. On-device timing verification still pending
> (see Verification section).

## Implementing now

### 1. Set-based `originalOrder` filter in queue restore — DONE
- **Where:** `QueueManagerService.loadQueue()` (`QueueManagerService.swift:614`)
- **Problem:** `persisted.originalOrder.filter { validTrackIDs.contains($0) }`
  with `validTrackIDs: Array` → O(n²). ~500M UInt64 compares at 23k tracks,
  on every cold-launch restore. Likely a large share of the ~470ms
  post-decode pipeline the backlog attributes to "batch-fetch + filter".
- **Fix:** build `Set(validTrackIDs)` once, filter against it. One line.
- **Risk:** none — pure lookup-structure swap, same output order.

### 2. Move queue checksum off the main thread — DONE
- **Where:** `QueueManagerService.saveQueue()` (`:362-389`) +
  `generateChecksum()` (`:498-504`); `QueuePersistenceService`.
- **Problem:** `saveQueue()` runs synchronously on main (called from
  nextTrack/previousTrack/playTrack/shuffle). It maps 23k IDs → decimal
  strings → joins (~500KB string) → SHA-256, per track change. Main-thread
  hitch scaling with queue size.
- **Fix:** the *synchronous state capture* is load-bearing (ghost-queue fix)
  but the checksum is not part of capture. Introduce `QueueSnapshot`
  (checksum-less PersistedQueue fields), capture it synchronously, and let
  `QueuePersistenceService.performSave` derive `PersistedQueue` — checksum
  included — inside a detached background task.
- **Deliberately NOT changing the hash input format** (comma-joined decimal
  string stays): byte-hashing would be ~10x faster but invalidates every
  existing on-disk queue checksum, costing users their queue once on
  upgrade. Off-main is the part that matters; format change can ride a
  future `PersistedQueue.version` bump if ever needed.
- **Risk:** low. Migration path (`migrateFromUserDefaults`) still builds a
  full `PersistedQueue` and routes through the internal
  `performSave(_ queue:)` overload.

### 3. Single-query playlist detail (kills the N+1 duration loop + name lookup) — DONE
- **Where:** `PlaylistDetailView.loadData()` (`:189-227`),
  `LibraryService` (`:927-958, :1225-1238`).
- **Problems:**
  - `getPlaylists().first { $0.id == pid }` materializes *every* playlist
    (the most expensive MPMediaQuery type) just to read one name.
  - Per-song `getDuration(forTrack:)` → one MPMediaQuery per track whenever
    the background-QoS search index isn't warm. Seconds for big playlists,
    gating the whole view.
  - Collage runs `albumPersistentID(forTrack:)` (4 more queries) for a
    property already on the fetched items.
  - All three read properties (`name`, `playbackDuration`,
    `albumPersistentID`) that sit on the single predicate-filtered playlist
    query we already run.
- **Fix:** new `LibraryService.getPlaylistDetail(for:)` returning
  `PlaylistDetail { name, tracks: [{song, duration, albumID}] }` from ONE
  filtered `MPMediaQuery.playlists()`. View consumes it; per-track duration
  loop and `albumPersistentID(forTrack:)` helper deleted. Mock counterpart
  in `MockLibraryService` (duration 0, albumID 0 — matches current DEBUG
  behavior; collage skips albumID 0).
- Also add a `[PERF] playlistDetail …` log line — this path was flagged as
  uninstrumented during the 2026-05-25 slow-playlist investigation.
- **Risk:** low. Same data source, fewer round trips. Sort order = playlist
  order, unchanged (`collection.items` order).

### 4. Lazy playlist track list — DONE
- **Where:** `PlaylistDetailView.trackList` (`:138-151`).
- **Problem:** plain `VStack` inside `ScrollView` builds N `TrackRow`s
  eagerly before first paint, and `ForEach(Array(songs.enumerated()),
  id: \.offset)` re-allocates the tuple array on every body render — which
  fires on every `audioPlayer` playback tick.
- **Fix:** `LazyVStack` + `ForEach(songs.indices, id: \.self)` — the exact
  pattern QueueView already uses (see comment at `QueueView.swift:131-136`).
- **Risk:** none observed in QueueView precedent; songs array is only
  replaced wholesale.

## Deferred (deliberate, do not silently pick up)

- **Skip full-library scan in queue restore** (`getSongs(by:)` materializes
  all 23k items; restore only *needs* the current track — rows hydrate
  lazily). **Blocked on the queue double-play bug**: lazy validation leaves
  dead IDs in the queue, and unplayable tracks currently cause a 2x-advance
  (dual `playbackEngine.play` in audioPlayer wrappers). Fix that first.
- **Read-back verification on every debounced save**
  (`QueuePersistenceService.writeToFile`): redundant with `.atomic` +
  checksum-on-load, but background QoS and harmless. Declined for now.
- **Playlists *list* slowness**: hypothesis (LibraryStore cache invalidating
  on `lastModifiedDate` bumped by routine playback) still unconfirmed.
  Wait for log evidence (`📚 LibraryPlaylists.cache stale …` +
  `[PERF] ensurePlaylists` without `(cache hit)`). If confirmed, fix is
  diff-based invalidation across all of LibraryStore, not playlist-specific.
- **Persisted `ensureSongs` cache** (~5.1s on device): library-tab item,
  out of scope here; highest-ROI remaining cold-launch lever per backlog.

## Verification

- Build Debug (mock path) **and** Release (`#if !DEBUG` MPMediaQuery path
  must compile — Debug builds don't touch it).
- Run ampTests; QueueBinaryCoder round-trip/truncation/legacy tests must
  stay green (PersistedQueue shape and wire format unchanged).
- On-device spot checks (manual, later): cold-launch queue restore timing
  log; open a large playlist and read the new `[PERF] playlistDetail` line;
  track-skip burst with a 20k+ queue should no longer hitch.
