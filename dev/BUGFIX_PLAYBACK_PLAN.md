# Bugfix plan: playback, persistence, notifications (2026-06-09)

Source: bug-hunt session following the queue/playlist perf work
(`PERF_QUEUE_PLAYLIST_PLAN.md`). B1 is evidenced in the 2026-06-09 device
log (`CurrentTrackSnapshot: saved — Real Man at 219.577s` — new track,
previous track's position).

Pre-existing context worth knowing: the 2026-04-26 "double-play / 2x-advance"
bug appears ALREADY FIXED in current code — AudioPlayerService wrappers no
longer call `playbackEngine.play` directly; everything routes through
`currentTrackDidChange` driven by `pendingUserAction` (fix option B from the
diagnosis), and direction-aware recovery is implemented in
`playbackDidFinish`. Device verification of that fix is still pending.

## B1. Stale playback position on track change — HIGH, log-evidenced
- **Where:** `QueueManagerService` — `currentPlaybackPosition` is only
  written by the playback timer (`AudioPlayerService.playbackTimeDidUpdate`)
  and `playPause`. Nothing resets it when navigation changes the track.
- **Effect:** `saveQueue` (queue file) and the debounced
  `CurrentTrackSnapshot` capture the *previous* track's position against the
  *new* track. Kill the app in the window → next launch eager-loads the new
  track at the old position (clamped to duration, so short tracks can land
  at their end and instantly auto-advance).
- **Fix:**
  - Set `currentPlaybackPosition = 0` on successful navigation, before the
    `saveQueue()` call: both `startPlayback` variants, `playTrack`,
    `nextTrack` (both branches incl. loop), `previousTrack`. NOT at the top
    of `nextTrack`/`previousTrack` — a failed navigation (end of queue, no
    loop) must not zero the still-current track's position.
  - Seed `currentPlaybackPosition = persisted.playbackPosition ?? 0` in the
    `loadQueue` restore branch (cases a/d) — same reasoning as the seeding
    `applyEagerTrackSnapshot` already does: otherwise a restore-without-play
    followed by background/kill persists position 0.
  - Fix the stale comment in reconcile case (b/c) claiming
    `restoredPlaybackPosition` is set during eager apply (it deliberately
    isn't; eager seeds `currentPlaybackPosition`).

## B2. No-asset-URL track leaves previous song loaded + skips recovery — HIGH
- **Where:** `PlaybackEngineService.play` / `loadWithoutPlaying` — nil
  `getAudioURL` → early `return`.
- **Effect:** playback dead-stops with no skip cascade, and `player` still
  holds the previous track (or the eager track in restore case d) while
  `currentTrack` shows the new one — play/pause then plays the wrong audio.
- **Fix:** introduce `PlaybackLoadError.noAssetURL`; on nil URL set
  `lastPlayedSong = song`, `pausedAt = 0` (matching the throw path's state)
  and route through `handleLoadFailure` — clears the player and enters the
  existing capped failure cascade.
- **Noted, not changed:** the cascade's recovery auto-*plays* the next track
  even when the failure came from `loadWithoutPlaying` (paused restore).
  Pre-existing behavior on the decode-throw path; aligning no-URL with it.
  Whether restore-failure should advance-paused instead is a follow-up UX
  question.

## B3. Lock-screen "next" replays current song when song-loop is on — MED
- **Where:** `nextTrackCommand` impersonates track completion
  (`delegate?.playbackDidFinish(successfully: true)`), which checks
  `isLoopingSong` first.
- **Fix:** post `"PlayNextTrack"` notification (mirror of the existing
  `"PlayPreviousTrack"` pattern); `AudioPlayerService` observes and calls
  `nextTrack()`. Behavior change: remote next now *preserves* play/pause
  state (Apple Music behavior) instead of force-playing.

## B4. `Thread.sleep(0.1)` on main in audio session config — MED
- **Where:** `ensureAudioSessionConfigured` (`PlaybackEngineService`).
  Pays a guaranteed 100ms main-thread stall on every resume after the
  30s pause cleanup deactivates the session.
- **Fix:** delete the sleep. It was superstition ("ensure session state is
  stable"); the -50 error in today's log fired *with* the sleep present, and
  the fallback path handles failures. **Needs device verification** that
  resume-after-cleanup still works (the sleep predates the AVAudioPlayer
  revert).

## B5. Notifications suppressed indefinitely after cold launch — MED, log-evidenced
- **Where:** `NotificationService` — `appWillEnterForeground` fires on cold
  launch (per today's log) and sets `isResumingFromBackground = true`, but
  `appDidBecomeActive` only schedules the 2s clear when
  `appWasInBackground == true` (false on cold launch). Flag stays stuck
  until the first real background→foreground cycle. Log evidence:
  "Skipping notification - resuming from background" 90s after launch.
- **Fix:** only set the flag in `appWillEnterForeground` when
  `appWasInBackground` is true.

## B6. Semaphore sync-over-async on main in notification path — MED
- **Where:** `NotificationService.shouldSendNotification` — two
  `DispatchSemaphore.wait()` calls (notification settings fetch, app state)
  on the caller's thread, which is main (called from `play()` via
  `scheduleTrackChangeNotification`). Blocks main per track change.
- **Fix:** keep the cheap synchronous checks (same-song, resuming flag,
  enabled, manual-selection, debounce) in `scheduleTrackChangeNotification`,
  then hop to a `@MainActor` Task for app-state + system-auth checks and the
  send. Delete `shouldSendNotification` and its semaphores.

## B7. Engine pause paths don't sync position to QueueManager — LOW
- **Where:** `seek(to:)`, interruption `.began`, BT-disconnect pause — all
  update engine-local position but never call
  `delegate?.playbackTimeDidUpdate`, so `currentPlaybackPosition` goes stale
  (e.g., seek-while-paused then kill → restore at pre-seek position).
- **Fix:** fire `delegate?.playbackTimeDidUpdate(...)` in those three spots.
  (Session-state sync for interruption/BT pause — `pauseSession()` — needs a
  delegate-protocol change; deferred, position sync covers the data loss.)

## B8. Unsynchronized debounce state in QueuePersistenceService — LOW
- **Where:** `pendingSave` / `saveWorkItem` / `changeCount` /
  `lastBackupTime` mutated from callers' executors and read on the serial
  `saveQueue` dispatch queue.
- **Fix:** confine all of it to the `saveQueue` queue (mutations via
  `saveQueue.async`/`sync`). Also clear `pendingSave` when the debounced
  work item fires (currently retains the last 23k-ID snapshot forever).

## B9. Cache-delete vs rebuild-save race in LibraryStore — LOW
- **Where:** `libraryDidChange` — unordered detached deletion of cache files
  races the reloads it triggers; a fast rebuild (playlists ≈30ms) can save a
  fresh cache and then have it deleted.
- **Fix:** await the deletion inside the reload Task, before invoking the
  `ensure*` calls. (A rebuild already in flight when the notification lands
  can still save post-deletion — accepted; the stale-date guard catches it
  next launch.)

## B10. PlaybackQueue songCache "FIFO" comment is wrong — TRIVIAL
- `songCache.keys.first` on a Dictionary evicts an arbitrary entry. Behavior
  is fine for a 50-entry cache; fix the comment, not the code.

## Verification
- Release + Debug builds, ampTests. ✅ 2026-06-09.
- **Device log 2026-06-10 00:07 verified:** B1 ✅ (`CurrentTrackSnapshot:
  saved — Es Demasiado Triste at 0.000s` on track change — was 219.577s
  pre-fix; eager restore also landed at the correct 2.002s), B4 ✅ (resume
  after 30s-cleanup session deactivation produced audio with no sleep),
  B5 ✅ (`isResumingFromBackground: false` post-cold-launch; notification
  skipped for the *correct* reason, manual selection). Still pending on
  device: B2 (play a known-unplayable track), B3 (lock-screen next with
  song-loop on), B5 end-to-end (notification appears when backgrounded +
  auto-advance), double-play 1x-advance check.
- **Open observation:** ~1.1–1.2s main-thread hang at startPlayback
  reproduced in both 06-09 and 06-10 logs, NOT correlated with queue size
  (23,792 vs 2,463 tracks). Candidates on the main thread inside the play
  chain: `AVAudioPlayer(contentsOf:)` + `prepareToPlay` (disk I/O),
  `updateNowPlayingInfo` → `getArtwork` (sync MPMediaQuery + artwork
  fetch), audio-session reconfigure (4 blocking AVAudioSession calls when
  the -50 fallback path runs). A second ~1.09s hang fires right when
  `ensureSongs` completes (publishing 23k-element arrays → SwiftUI diff).
  Needs a Time Profiler pass — do not guess-fix.
- Device checks (manual): B1 — skip tracks rapidly, kill app, relaunch:
  position must be 0:00 for the landed track (snapshot log should show the
  new track at ~0s, never the prior track's position). B3 — enable song
  loop, lock screen next must advance. B4 — pause >30s, resume; audio must
  start. B5 — cold launch, background the app, change track: notification
  must appear (previously suppressed until first background cycle).
