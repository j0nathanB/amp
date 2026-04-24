# Queue Current-Track Pin — Design Finalization

## TL;DR

The bidirectional pin already exists in `QueueView.swift`, but the in-list current row and the pinned overlay can both be visible during scroll transitions — that's the "two navy rows" the user noticed. Three changes finalize the design:

1. **Hide the in-list current row when the pin is showing** so exactly one navy row is ever visible.
2. Add a user setting for **default pin position** (top/bottom) and use it as the anchor for `scrollToCurrent`.
3. Add **play/pause button + elapsed time** to the navy-inverted current row.

Auto-scroll on track change stays as-is (intentional — keeps the queue from being a place users linger).

---

## Design Recap

- Exactly **one** navy-highlighted row visible at any time.
- The highlighted row's default state is **pinned** at the configured edge (top or bottom).
- When the user scrolls past it, it unpins and moves freely through the viewport with the rest of the list.
- When it reaches the opposite edge of the viewport, it pins there.
- Setting (`Settings → Pin currently playing track to top`, default OFF = bottom) controls the anchor used for initial display and auto-scroll on track change.
- Auto-scroll on every track change stays — when a new song starts, the queue snaps to the configured anchor.
- Pinned row shows: position/title/artist (existing), **play/pause button**, and **elapsed time** (replaces duration once playback begins; freezes on pause).
- Tap on the highlighted row (pinned or in-list) toggles play/pause. Tap on other rows skips to that song. (Existing.)
- Played songs stay above the current row, undimmed. Short queues → no pin. No scrubbing on the row. (All existing.)
- Snap, no animated handoff.

---

## Current Code State

### What's already correct
- `QueueView.swift:171-180` — `pinState` calculation (top/bottom/none from scroll geometry).
- `QueueView.swift:145-165` — overlay swaps blue overflow bar for pinned row at each edge.
- `QueueView.swift:228-234` — `handleTap`: tap current = playPause(), tap other = playTrack(at:).
- `QueueView.swift:135-138` — auto-scroll on appear and on `currentIndex` change. **Keep.**
- `TrackRow.swift:116-134` — navy-inverted variant with white-on-navy styling.
- Played-songs-stay, no-dimming, short-queue-no-pin all fall out of existing logic.

### What needs changing
- `QueueView.swift:113-122` — in-list `QueueRow` always renders with `isCurrent: index == currentIndex`. **When pinned, render an invisible placeholder so only the overlay shows.**
- `QueueView.swift:236-245` — `scrollToCurrent` hardcoded to `anchor: .top`. **Make it depend on the new setting.**
- `SettingsView.swift:8-14` — `SettingsService` only has `showLyrics`. **Add `queuePinDefaultTop`.**
- `SettingsView.swift:68-77` — settings section has one toggle. **Add a second.**
- `TrackRow.swift:116-134` — `navyInverted` shows static duration, no button. **Add play/pause + elapsed-time slot.**
- `QueueView.swift:286-314` — `QueueRow` doesn't observe playback state. **Plumb `isPlaying` + `playbackTime` to the current row only.**

---

## Concrete Changes

### 1. SettingsService — add pin-position preference

`SettingsView.swift:8-14`

```swift
final class SettingsService: ObservableObject {
    static let shared = SettingsService()

    @AppStorage("showLyrics") var showLyrics: Bool = true
    @AppStorage("queuePinDefaultTop") var queuePinDefaultTop: Bool = false  // false = bottom

    private init() {}
}
```

`SettingsView.swift:68-77` — add toggle:

```swift
private var settingsSection: some View {
    VStack(spacing: 16) {
        BrutalistToggle(
            label: "Show lyrics button when available",
            isOn: $settings.showLyrics
        )
        BrutalistToggle(
            label: "Pin currently playing track to top",
            isOn: $settings.queuePinDefaultTop
        )
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 28)
}
```

Default OFF = pins to bottom (per user spec).

### 2. QueueView — single-row guarantee + use configured anchor

Add `@ObservedObject private var settings = SettingsService.shared` near line 24.

**Hide in-list current row when pinned.** Modify the `ForEach` body (line 113-122) to render an invisible placeholder of the same height when the pin is showing:

```swift
ForEach(audioPlayer.playbackQueue.trackIDs.indices, id: \.self) { index in
    let trackID = audioPlayer.playbackQueue.trackIDs[index]
    let isCurrent = index == audioPlayer.currentIndex

    if isCurrent && pinState != .none {
        // Pin is showing in the overlay. Reserve the row's vertical
        // space so other rows don't shift, but don't render the navy
        // chrome — there must only ever be ONE highlighted row visible.
        Color.clear
            .frame(height: currentRowHeight)
            .id(index)
    } else {
        QueueRow(
            index: index,
            trackID: trackID,
            isCurrent: isCurrent
        ) {
            handleTap(at: index)
        }
        .id(index)
    }
}
```

Move `rowHeight` and `currentRowHeight` from file-level `private let` to nested in `QueueView` (or expose them somehow) so the `ForEach` can reference `currentRowHeight`. They're already file-level `private let`, so the `ForEach` body can read them directly — no move needed.

**Update `scrollToCurrent`** (line 236-245) to use the configured anchor. Both the initial `.onAppear` scroll and the `.onChange(of: currentIndex)` auto-scroll go through this function, so this single change carries to both:

```swift
private func scrollToCurrent(proxy: ScrollViewProxy, animated: Bool) {
    guard let index = audioPlayer.playbackQueue.currentIndex else { return }
    let anchor: UnitPoint = settings.queuePinDefaultTop ? .top : .bottom
    if animated {
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(index, anchor: anchor)
        }
    } else {
        proxy.scrollTo(index, anchor: anchor)
    }
}
```

The existing `.onAppear` and `.onChange(of: audioPlayer.currentIndex)` (lines 135-138) stay unchanged — they call `scrollToCurrent` which now respects the setting.

### 3. TrackRow — play/pause button + elapsed time slot

Add an optional playback-state param so the change is opt-in and TrackRow's other callers (Album Detail, Playlists) are unaffected.

`TrackRow.swift:19-47`:

```swift
struct TrackRow: View {
    let position: String
    let title: String
    let artist: String?
    let duration: String
    let isCurrent: Bool
    let prominent: Bool
    let playbackState: PlaybackState?   // new — non-nil only for the queue's current row
    let onTap: () -> Void
    let onLongPress: (() -> Void)?

    struct PlaybackState {
        let isPlaying: Bool
        let elapsed: TimeInterval
    }

    init(
        position: String,
        title: String,
        artist: String? = nil,
        duration: String,
        isCurrent: Bool,
        prominent: Bool = false,
        playbackState: PlaybackState? = nil,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil
    ) {
        // ...assignments...
    }
}
```

Update `navyInverted` (line 116-134):

```swift
private var navyInverted: some View {
    HStack(spacing: 0) {
        if !prominent {
            Text(position)
                .font(.trackNumber)
                .foregroundStyle(Color.ampWhite)
                .frame(width: 40, alignment: .trailing)
        }
        titleStack(titleColor: .ampWhite, artistColor: .ampInversionLabel, boldTitle: true)
            .padding(.leading, prominent ? 24 : 16)
        Spacer(minLength: 12)
        if let state = playbackState {
            playPauseButton(isPlaying: state.isPlaying)
                .padding(.trailing, 12)
            Text(timeLabel(elapsed: state.elapsed))
                .font(.timestamp)
                .foregroundStyle(Color.ampWhite)
                .padding(.trailing, 24)
                .monospacedDigit()
        } else {
            Text(duration)
                .font(.timestamp)
                .foregroundStyle(Color.ampWhite)
                .padding(.trailing, 24)
        }
    }
    .frame(maxWidth: .infinity, minHeight: navyHeight, maxHeight: navyHeight)
    .background(Color.ampNavy)
}

@ViewBuilder
private func playPauseButton(isPlaying: Bool) -> some View {
    Button {
        onTap()  // delegate to row's tap handler — already toggles play for current track
    } label: {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.ampWhite)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

private func timeLabel(elapsed: TimeInterval) -> String {
    // Show elapsed once playback has started for this track; before
    // playback starts (fresh queue, just resumed app), fall back to
    // total duration so the slot isn't blank.
    if elapsed > 0 {
        let total = Int(elapsed.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    return duration
}
```

The button's tap delegates to `onTap`, which already toggles play/pause for the current track (`handleTap` in QueueView). One source of truth for "tap the playing row → toggle." The button is a visual affordance + a clearer hit target on the right side.

### 4. QueueRow — pass playback state to current row

`QueueView.swift:286-298` — extend `TrackRow` call:

```swift
var body: some View {
    TrackRow(
        position: "\(index + 1)",
        title: song?.title ?? "…",
        artist: song?.artist,
        duration: formatDuration(duration),
        isCurrent: isCurrent,
        prominent: true,
        playbackState: isCurrent ? TrackRow.PlaybackState(
            isPlaying: audioPlayer.isPlaying,
            elapsed: audioPlayer.playbackTime
        ) : nil,
        onTap: onTap,
        onLongPress: { /* existing */ }
    )
    // ...existing .task...
}
```

Add `@EnvironmentObject var audioPlayer: AudioPlayerService` to `QueueRow` (line 264-275 area).

**Performance note:** `QueueView.body` already re-renders on every `playbackTime` tick (called out at line 109-112 in existing comments). Adding observation in `QueueRow` doesn't change that — only the current-row instance reads `playbackTime`, and only its body recomputes. Other rows in the LazyVStack short-circuit to `playbackState: nil`.

### 5. Pinned row inherits the same change automatically

`pinnedCurrentRow` (line 192-204) constructs a `QueueRow` with `isCurrent: true`, so the play/pause button and elapsed time appear in the pinned row without further work. The single-row guarantee from change 2 means the in-list slot is invisible whenever this overlay is showing.

---

## Verification Plan

After implementation, manually verify on simulator (iPhone 16):

1. **Single navy row at all times.** Scroll the queue back and forth across the current row. At no point should two navy rows be visible. The in-list slot should be empty whenever the pin is showing.
2. **Default-bottom (default).** Cold launch with mid-queue track → row appears at bottom of viewport.
3. **Default-top.** Toggle setting → row appears at top.
4. **Auto-scroll on track change** snaps queue back to anchor (top or bottom per setting).
5. **Pin transitions** — scroll past the row → pins to whichever edge it left from. Scroll back → unpins as it re-enters viewport.
6. **Play/pause button.** Tap button on pinned (or in-list) current row → toggles. Icon updates. Elapsed freezes on pause.
7. **Elapsed time fallback.** Fresh queue, no playback yet → row shows duration. Hit play → switches to elapsed.
8. **Tap row vs tap button.** Both toggle play (no double-fire, no conflict).
9. **Short queue.** Queue with 3 songs → no pin, current row sits in its natural position.

---

## Risks / Open Questions

1. **`Color.clear` placeholder height in LazyVStack.** Need to verify `Color.clear.frame(height: 84)` actually reserves 84pt in `LazyVStack` (it should, but `LazyVStack` sometimes treats `Color.clear` as having intrinsic zero size when layout-measuring lazily). If layout collapses, swap to `Spacer().frame(height: 84)` or a transparent rectangle with explicit `.frame(maxWidth: .infinity, height: 84)`.
2. **`pinState` recomputation timing.** If `onScrollGeometryChange` doesn't fire on every frame during fast scroll, the pin/in-list swap might lag by 1-2 frames at the boundary. Test with rapid swipes — if visible flicker, may need to widen the "consider pinned" range slightly (e.g., trigger `.pinnedTop` when row's bottom is within 4pt of viewport top, not just past it).
3. **Button-vs-row gesture conflict.** SwiftUI Button inside a parent with `.onTapGesture` sometimes lets the parent intercept first. If the play/pause button doesn't fire, switch the row's tap from `.onTapGesture` to a separate hit region that excludes the button bounds, or convert the button to a tap-region overlay that calls `onTap()` directly.
4. **`playbackTime` update rate.** It's `TimeInterval` (Double). Formatting rounds to whole seconds, so the visible label changes at most once per second. If `PlaybackEngineService` publishes more frequently than ~10Hz, `monospacedDigit()` plus the rounding should mask it, but watch for jitter.

---

## Out of Scope

- Dragging/scrubbing the elapsed time → opening Now Playing or seeking.
- Album art on the pinned row.
- Animated handoff between in-list and pinned (snap, per spec).
- Playback controls on non-current rows.
- Per-row swipe actions (remove from queue, reorder, etc.).
