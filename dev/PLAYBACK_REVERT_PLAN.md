# Playback engine revert + navigation fix

## Why

Two bugs, one root cause:

**Surface bug:** Pressing prev/next or tapping a track in the queue can advance currentIndex by 2 instead of 1, causing prev↔next loops between adjacent songs and "tap song A plays song B." Reproduced 2026-04-26 with two specific tracks ("Viz - Le Tigre", "Ivan Meets GI Joe - The Clash") that fail to load on device.

**Root cause #1 (engine):** Commit `4f6b517` (2026-04-17) migrated `PlaybackEngineService` from `AVAudioPlayer` to `AVAudioEngine` + `AVAudioFile` + `AVAudioPlayerNode` to support per-band equalizer envelopes. `AVAudioFile(forReading:)` cannot open `ipod-library://` URLs (the URL scheme `MPMediaItem.assetURL` returns for tracks added to the iOS Music library). `AVAudioPlayer(contentsOf:)` handles that scheme natively. So a subset of the user's local tracks now fail at file-open where they previously worked. The equalizer feature has since been removed (commit `5af1405`), making AVAudioEngine no longer load-bearing.

**Root cause #2 (navigation):** `audioPlayer.{playTrack, nextTrack, previousTrack}` call `queueManager.{playTrack/nextTrack/previousTrack}` *and then* explicitly call `playbackEngine.play(track)`. The queueManager call already fires `delegate.currentTrackDidChange(track) → playbackEngine.play(track)` once. So `play()` runs twice per user action. Harmless on working tracks (second call replaces first's schedule). On unplayable tracks each `play()` triggers the failure-recovery cascade (`playbackDidFinish(false)` → `queueManager.nextTrack()`), advancing currentIndex twice for one user action.

The double-play pattern is structurally identical between commit `7375e15` (pre-redesign "stable") and HEAD — same wrappers, same delegate, same recovery. It's been latent the whole time. The AVAudioEngine migration exposed it by making the failure-recovery cascade observable on tracks that previously played fine.

A third issue is also worth fixing while we're here: `playbackDidFinish(successfully: false)` always recovers with `nextTrack()`. After fixing the double-play, prev through a broken track will now consistently land you back on the song you started on (broken track fails → forward recovery → original track). Going backward should recover backward.

## Goals

1. Replace AVAudioEngine playback path with AVAudioPlayer. Restore native `ipod-library://` support.
2. Eliminate the double-play architectural smell. Single playback path through the delegate.
3. Direction-aware failure recovery (prev failures recover backward, next/auto recover forward).
4. Preserve every currently-working feature: eager-load fast path, route detection (BT/wired indicators), Now Playing info / lock-screen controls, queue persistence, system-volume sync, 30-second pause cleanup.

## Non-goals

- No changes to `PlaybackEngineService`'s **public API**. Delegate protocol, `@Published` properties, public methods (`play`, `playPause`, `seek`, `loadWithoutPlaying`, `loadWithURL`, `refreshNowPlayingInfo`) all keep the same signatures so callers don't change shape.
- No changes to `QueueManagerService`, `PlaybackQueue`, `QueuePersistenceService`, or `CurrentTrackSnapshot`. Queue logic and persistence stay as-is.
- No rename of `EqualizerBars` (it's been repurposed as a loading-indicator view; the audio-analysis equalizer is already gone).
- No UI changes (NowPlayingView, QueueView, etc. — they read the same `@Published` properties).

## Phase 1 — `PlaybackEngineService` revert to AVAudioPlayer

Single-file change: `amp/PlaybackEngineService.swift` (~1090 lines → ~700–750 lines).

### State to remove

```
private let engine = AVAudioEngine()
private let playerNode = AVAudioPlayerNode()
private var file: AVAudioFile?
private var segmentStartOffset: TimeInterval = 0
private var currentScheduleToken = UUID()
```

### State to add / restore

```
private var player: AVAudioPlayer?         // primary playback object
// (NSObject subclass already present; conform to AVAudioPlayerDelegate)
```

### Method-by-method migration

| Method | Before (AVAudioEngine) | After (AVAudioPlayer) |
|---|---|---|
| `setupAudioGraph()` | `engine.attach + connect` | **Delete entirely.** No graph to set up. |
| `ensureEngineRunning()` | starts engine if not running | **Delete.** AVAudioPlayer self-manages. |
| `play(song:isManualSelection:)` | calls `schedulePlayback` | `try AVAudioPlayer(contentsOf: url)`, set `delegate = self`, `volume`, `prepareToPlay`, `play()`. Same isSameSong / pausedAt resume logic. Same notification scheduling. |
| `playPause()` | `playerNode.pause/play` + isResumingFromPause + reschedule-on-seek dance | `player?.pause()` / `player?.play()`. AVAudioPlayer preserves position automatically. The reschedule-on-seek branch (lines ~200–215 of current `playPause`) is unnecessary — delete. |
| `seek(to:)` | `playerNode.stop()` + `scheduleSegment(startingFrame:)` | `player?.currentTime = clampedTime` + maybe `player?.prepareToPlay()` if paused. |
| `loadWithoutPlaying(song:)` | `schedulePlayback(autoPlay: false)` | `try AVAudioPlayer(contentsOf: url)`, `delegate = self`, `prepareToPlay`, **don't** call `play()`. |
| `loadWithURL(song:url:seekTo:)` | `try AVAudioFile(forReading: url)` + scheduleSegment | `try AVAudioPlayer(contentsOf: url)`, `currentTime = seekTo`, `prepareToPlay`. Returns false on throw exactly like today. |
| `schedulePlayback(url:fromSeconds:autoPlay:)` | shared helper | **Delete.** Inline the AVAudioPlayer init in the three callers (`play`, `loadWithoutPlaying`, `loadWithURL`). The shared helper saved code under the old engine; under AVAudioPlayer the bodies are short enough that inlining is clearer. Keep `consecutiveLoadFailures` accounting in each catch block (or extract a tiny `handleLoadFailure(error:)` if duplication grates). |
| `currentPlaybackTime()` | `playerNode.lastRenderTime` → `playerTime(forNodeTime:)` → `sampleTime / sampleRate + segmentStartOffset` | `player?.currentTime ?? pausedAt`. |
| `handleScheduleCompletion(token:)` | gates on token, calls delegate.playbackDidFinish(true) | **Delete.** Replaced by `audioPlayerDidFinishPlaying(_:successfully:)` delegate method. |
| `audioPlayerDidFinishPlaying(_:successfully:)` | n/a | **Add.** `consecutiveLoadFailures = 0` on success; `delegate?.playbackDidFinish(successfully: flag)`. |
| `audioPlayerDecodeErrorDidOccur(_:error:)` | n/a | **Add.** Log + `delegate?.playbackDidFinish(successfully: false)` so the recovery cascade fires. |
| `cleanupAudioResourcesOnPause()` | `playerNode.stop(); file = nil` | `player?.stop(); player = nil`. Keep the 30s cleanup timer logic. |
| `resumeFromPause(song:at:)` | inline `schedulePlayback` call | inline AVAudioPlayer init + seek + play. |
| `cleanupAudioResourcesOnStop()` | reset segmentStartOffset etc. | reset `pausedAt`, `songDuration`, `playbackTime`. |

### Time tracking

The existing `startTimer` polls `currentPlaybackTime()` every 0.1s and pushes to `@Published playbackTime` + `delegate?.playbackTimeDidUpdate`. **Keep this exact polling loop**, just point `currentPlaybackTime()` at `player?.currentTime`. AVAudioPlayer doesn't fire native time-update callbacks, so the timer is still the right mechanism.

### State to keep verbatim

These are all AVAudioSession / MPNowPlayingInfoCenter / route-related and not engine-coupled:

- `audioSessionConfigured`, `ensureAudioSessionConfigured`, `deactivateAudioSessionIfNeeded`
- `setupNotifications` (route changes, interruptions, app lifecycle)
- `updateCurrentOutputName`, `isBluetoothRouteActive`, `isWiredRouteActive`
- `volumeView`, `volumeObserver`, `updateSystemVolume`
- `setupRemoteCommandCenter`, `teardownRemoteCommandCenter`
- `updateNowPlayingInfo`, `updateNowPlayingInfoTime`, `getArtwork`
- `getAudioURL`
- `lastPlayedSong`, `pausedAt`, `lastNowPlayingUpdate`
- `pauseCleanupTimer`, `scheduleDelayedCleanup`, `cancelDelayedCleanup`
- `consecutiveLoadFailures`, `maxConsecutiveFailures`
- `scheduleTrackChangeNotification`
- `notifyMemoryCleanup` coordination call

### State to drop

- `isResumingFromPause` flag — was needed to suppress notifications on a complex AVAudioEngine resume path that no longer exists. AVAudioPlayer's pause/resume is self-contained.

### File-open strategy

`AVAudioPlayer(contentsOf:)` throws on:
- Genuinely unreadable file (corrupt, unsupported format)
- Missing file
- Permission issue

It does **not** throw on `ipod-library://` URLs that point at local Music-library tracks — that's the whole point. If it does still throw on a particular track in the new world, we want the recovery cascade to fire (already wired up via the `consecutiveLoadFailures` counter and `delegate.playbackDidFinish(false)`).

### Engine config-change recovery (commit `f7be754`) becomes obsolete

The `AVAudioEngineConfigurationChange` notification handler that restarts the engine after route changes goes away. AVAudioPlayer doesn't have this failure mode (it routes through the audio session, which we still observe via `AVAudioSession.routeChangeNotification`). Net: less code, fewer failure modes.

## Phase 2 — `AudioPlayerService` single-path + direction-aware recovery

Single-file change: `amp/AudioPlayerService.swift`.

### Replace `transitionState` with `pendingUserAction`

```swift
private enum UserAction {
    case none           // auto-advance from track-end, eager load, queue restore
    case selectTrack    // user tapped a track or hit "play this" — force play, no notification
    case nextTrack      // user pressed next — preserve isPlaying, no notification, recover forward
    case previousTrack  // user pressed prev — preserve isPlaying, no notification, recover backward
}
private var pendingUserAction: UserAction = .none
```

This single field replaces both `transitionState` (which was about delegate-double-play suppression) and the `isManualSelection` flag-passing. It also encodes the recovery direction without a separate field.

`isAutoAdvancing` — keep, still distinguishes "track ended naturally" from "user-driven change."

### `startPlayback` variants — drop the explicit play

Today:
```swift
transitionState = .transitioning(to: startSong)
queueManager.startPlayback(...)
navigation.navigateToNowPlaying()
if let track = queueManager.currentTrack {
    playbackEngine.play(song: track, isManualSelection: true)
}
transitionState = .none
```

After:
```swift
pendingUserAction = .selectTrack
defer { pendingUserAction = .none }
queueManager.startPlayback(...)
navigation.navigateToNowPlaying()
// delegate.currentTrackDidChange will see .selectTrack and play(isManualSelection: true)
```

The two-step pre-hydrate-then-set-state pattern (used today to know `startSong` before calling queueManager) collapses — we don't need to know the song in advance because the delegate path handles it.

### `playTrack`, `nextTrack`, `previousTrack` — drop the explicit play

```swift
func playTrack(at index: Int) {
    pendingUserAction = .selectTrack
    defer { pendingUserAction = .none }
    _ = queueManager.playTrack(at: index)
}

func nextTrack() {
    pendingUserAction = .nextTrack
    defer { pendingUserAction = .none }
    _ = queueManager.nextTrack()
}

func previousTrack() {
    if playbackTime > 4.0 {
        playbackEngine.seek(to: 0)
        return
    }
    pendingUserAction = .previousTrack
    defer { pendingUserAction = .none }
    _ = queueManager.previousTrack()
}
```

The `> 4.0s seek-to-zero` branch in `previousTrack` is preserved verbatim — that's correct behavior, not part of the bug.

### `currentTrackDidChange(_ track:)` — single decision point

```swift
func currentTrackDidChange(_ track: Song?) {
    guard let track = track else { return }

    let isManual: Bool
    let shouldPlay: Bool

    switch pendingUserAction {
    case .selectTrack:
        // User explicitly chose this track — force play, suppress notification.
        isManual = true
        shouldPlay = true
    case .nextTrack, .previousTrack:
        // User-driven nav — preserve current play/pause state, suppress notification.
        // (isAutoAdvancing handles in-cascade recovery: those plays should keep playing.)
        isManual = true
        shouldPlay = isAutoAdvancing || isPlaying
    case .none:
        // Auto-advance from track-end, queue restore, eager-load reconcile.
        isManual = false
        shouldPlay = isAutoAdvancing || isPlaying
    }

    if shouldPlay {
        playbackEngine.play(song: track, isManualSelection: isManual)
    } else {
        playbackEngine.loadWithoutPlaying(song: track)
        if let position = queueManager.restoredPlaybackPosition, position > 0 {
            playbackEngine.seek(to: position)
            queueManager.restoredPlaybackPosition = nil
        }
    }
}
```

The `transitionState`-based skip guard (`if case .transitioning(let target) = ...; track.id == target.id { return }`) is **deleted** — there's only one playback path now, nothing to suppress.

### `playbackDidFinish(successfully:)` — direction-aware recovery

```swift
func playbackDidFinish(successfully: Bool) {
    if successfully {
        if isLoopingSong, let track = currentTrack {
            playbackEngine.play(song: track, isManualSelection: false)
        } else {
            isAutoAdvancing = true
            defer { isAutoAdvancing = false }
            _ = queueManager.nextTrack()
        }
    } else {
        guard queueManager.playbackQueue.trackIDs.count > 1 else { return }
        isAutoAdvancing = true
        defer { isAutoAdvancing = false }

        // Recover in the direction the user was navigating.
        // .none / .nextTrack / .selectTrack → forward
        // .previousTrack → backward (with no fallback — let cascade or
        // consecutiveLoadFailures cap halt us, don't strand the user mid-queue
        // by jumping forward unexpectedly)
        if case .previousTrack = pendingUserAction {
            _ = queueManager.previousTrack()
        } else {
            _ = queueManager.nextTrack()
        }
    }
}
```

`pendingUserAction` is set in the synchronous wrapper and the recovery cascade fires synchronously from `playbackEngine.play()` (which fires from the delegate path), so the flag is still set when `playbackDidFinish` runs. Verified by tracing the call stack: `previousTrack()` → `pendingUserAction = .previousTrack` → `queueManager.previousTrack()` → `delegate.currentTrackDidChange` → `playbackEngine.play()` → throw → `delegate.playbackDidFinish(false)` (synchronous via `audioPlayerDecodeErrorDidOccur` or the constructor catch).

### Edge case: prev recovery hits start of queue

`queueManager.previousTrack()` returns nil at index 0. When recovery direction is backward and previousTrack returns nil, we don't fall back to nextTrack — that would suddenly jump the user forward, which is more confusing than failing silently. The user pressed prev; if they hit the start of the queue with broken tracks ahead, prev appears to do nothing. They can always press next to escape. `consecutiveLoadFailures` (capped at 5) prevents any pathological infinite recursion.

## Phase 3 — Verify

Before committing, run through these manually on device. Type-check / build pass is necessary but not sufficient.

### Working-track happy paths (regression check)

- Tap a track in queue while playing → that track plays, no notification.
- Tap a track in queue while paused → that track starts playing, no notification.
- Press next while playing → next plays, no notification.
- Press next while paused → next loaded, **stays paused**, no notification.
- Press prev within first 4s of song → goes to actual prev track.
- Press prev after 4s into song → seeks current track to 0.
- Track ends naturally → next plays automatically, **notification fires** (user is not in the app, this is correct).
- End of queue with loop on → wraps to track 0.
- End of queue with loop off → playback stops.
- Pause for 30s+ → memory cleanup fires, file released. Press play → resumes from saved position.
- Background → foreground while playing → continues playing.
- BT connect/disconnect mid-playback → audio routes correctly, indicator updates, no crash.

### Broken-track paths (the bug fix)

(Repro: any track that fails AVAudioPlayer init — currently rare with AVAudioPlayer, but use a corrupt test file or temporarily edit `getAudioURL` to return a bad URL for one specific track.)

- Tap broken track from queue → recovery to next-playable, currentIndex advances by 1, not 2.
- Press next when next is broken → recovery to next-after-broken, advances by 2 total (skip + recovery), not 3.
- Press prev when prev is broken → recovery to prev-of-broken, advances **backward** by 2 total, not forward.
- Press prev when prev is broken AND prev-of-broken is also broken → cascade backward, capped by `consecutiveLoadFailures`.
- Two adjacent broken tracks in middle of queue, navigate prev/next over the gap → no loop between two anchors.

### Cold-launch paths

- Eager-load hit (track snapshot exists, URL still resolves) → play button works within ~50ms, no audio glitch.
- Eager-load miss (snapshot file absent or URL stale) → falls through to normal queue restore, play button works once restore completes.
- Queue restore loads a track that fails AVAudioPlayer init → loadWithoutPlaying triggers the failure cascade — verify this doesn't auto-advance a paused queue. (May want a guard: don't advance during cold-restore loadWithoutPlaying.)

### iCloud-style URL paths (the reason we're doing this)

- Specifically test the two tracks the user reported ("Viz - Le Tigre", "Ivan Meets GI Joe - The Clash") — confirm they now play directly without triggering the recovery cascade at all. This is the success criterion for Phase 1.

## Risk & rollback

**Concentrated risk:** Phase 1 rewrites the playback path. If something subtle breaks (a particular file format, a particular pause/resume sequence, a particular AVAudioSession interaction), the symptom is "audio doesn't play" or "audio glitches" — high visibility, easy to detect.

**Rollback:** Both phases land as separate commits. If Phase 1 causes regressions, `git revert` the Phase 1 commit; Phase 2 (the navigation cleanup) is independent and can stand on its own — the double-play fix is still valid against the AVAudioEngine code path. If both phases land cleanly and a regression appears later, both can revert without affecting QueueManagerService / persistence / UI.

**Non-rollback option for Phase 2:** Even without Phase 1, the navigation fix removes the 2x-advance behavior. With Phase 1 done first, Phase 2 is mostly a code-cleanup since the failure cascade rarely fires. Doing both together is the right call; this is just to note that Phase 2 has independent value.

## Order of operations

1. Phase 1 commit: PlaybackEngineService AVAudioPlayer revert. Verify all working-track happy paths on device. Verify Viz / Ivan now play.
2. Phase 2 commit: AudioPlayerService single-path + direction-aware recovery. Verify navigation paths.
3. Update `CLAUDE.md` "Recent Improvements" section with both changes.
4. (Out of scope here, mention only) Consider opening a follow-up to delete commit `f7be754`'s AVAudioEngine config-change recovery code if any of it lingered after Phase 1.

## Estimate

Phase 1: ~300–400 lines diff (mostly deletes from `PlaybackEngineService.swift`). Few hours including device verification.

Phase 2: ~50–80 lines diff in `AudioPlayerService.swift`. ~30 minutes including verification.
