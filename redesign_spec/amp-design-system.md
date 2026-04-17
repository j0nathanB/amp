# amp Design System

**Status:** ready for implementation
**Platform:** iOS (SwiftUI)
**Scope:** full design language rework — color palette, typography, component primitives, view-by-view layouts, interactions

This document is the authoritative design spec for the amp redesign. It supersedes any earlier design notes on color, currently-playing indication, track info affordance, or tab structure.

---

## 1. Design philosophy

amp is a brutalist music player for local iTunes libraries. The design language is:

- **Disciplined, semantic color.** Every hue has one job. Green = playable, yellow = organizational header, dark navy = structural shadow AND currently-active state.
- **Thick black strokes (2px) on every object edge.** No hairline borders, no soft shadows, no gradient fills.
- **Offset indigo shadows.** Every brutalist element casts a solid-color offset shadow bottom-left of itself, 4–6px deep. No blur.
- **One affordance per element.** No dual-purpose controls. A tappable thing does one thing; if you need another, add another control.
- **Inversion over pink.** Currently-playing rows, active toggles, and selected tabs all use full-width navy (#004D70) backgrounds with white text. Pink is gone.
- **Minimal chrome, minimal text.** Mono font for structural labels, sans for content. Middle-dot `·` as metadata separator.

amp is a **player**, not a library manager. iTunes owns the library; amp reads it. See §9 for sync constraints.

---

## 2. Color tokens

| Token | Hex | Semantic role |
|---|---|---|
| `ampWhite` | `#FFFFFF` | Base surface, default button fill |
| `ampBlack` | `#000000` | 2px strokes, primary text |
| `ampGreen` | `#52DE79` | **Playable action only** — play buttons, play-all bars, scrubber fill |
| `ampYellow` | `#FBDC3D` | **Organizational header only** — view-level titles, section dividers. Never foreground text color (fails WCAG on white, 1.4:1). |
| `ampNavy` | `#004D70` | (1) Offset shadow on every brutalist element, (2) "Currently active" state inversion fill |
| `ampCream` | `#F5F3EC` | Outer canvas background behind the content frame (see §2.1) |
| `ampMutedText` | `#666666` | Metadata, secondary info, timestamps when not active |
| `ampMutedTextStrong` | `#999999` | Track numbers, tertiary info |
| `ampInversionLabel` | `#8EB0C2` | Muted label color on navy backgrounds (for 2-column metadata zones) |
| `ampDivider` | `#E5E5E5` | Hairline dividers between list rows |

### 2.1 App background surface

The app uses a two-layer background system:

- **Outer canvas:** `ampCream` (`#F5F3EC`) — the surface behind and around the main content frame. This is what makes the navy offset shadows visible; without it, a navy shadow on a white background works fine, but a white content card on a white canvas loses its edge. The cream provides just enough contrast (ratio ~1.08:1 against white) to separate the content frame from the device background without introducing a competing color.
- **Content frame:** `ampWhite` (`#FFFFFF`) — the actual app content area where all views render.

In practice this means the root `ZStack` or window background is `ampCream`, and each view's content area is a white rectangle with a 2px black stroke sitting on top of it. The cream is visible as a narrow strip around the edges and — critically — as the surface behind every offset shadow.

**Migration note:** the current app uses full-bleed white (`#FFFFFF` edge-to-edge). This change adds the cream canvas behind it. The content itself stays white; nothing inside the views changes color. The only visual difference is that the outermost background shifts from white to cream, and the content area gains a 2px black stroke border separating it from that canvas. Implementation: set the window/scene background to `ampCream` and ensure each tab's root view has an explicit white fill rather than inheriting `.clear`.

### Removed from palette

- ~~`#BED52F` lime green~~ — dropped entirely
- ~~`#EA7586` pink~~ — was currently-playing indicator; replaced by navy inversion
- ~~`#115423` dark spruce~~ — retained in code as a legacy token if anywhere still references it, but not used in any new component

### Contrast verification (all WCAG AAA-compliant)

| Combination | Ratio |
|---|---|
| Black on white | 21:1 |
| Black on green `#52DE79` | 13.0:1 |
| Black on yellow `#FBDC3D` | 14.6:1 |
| White on navy `#004D70` | 9.8:1 |
| `#8EB0C2` on navy | 4.6:1 (labels only, acceptable) |
| `#666` on white | 5.7:1 |

---

## 3. Typography

Fonts: **Atkinson Hyperlegible Next** (sans) and **Atkinson Hyperlegible Mono** (mono), bundled from the Braille Institute. Both are chosen specifically for legibility at all sizes.

| Style | Font | Weight | Size | Used for |
|---|---|---|---|---|
| `.viewTitle` | Mono | 700 | 22pt | Yellow block headers (LIBRARY, Tracks, Lyrics, Songs, etc.) |
| `.playAllBarTitle` | Mono | 700 | 18pt | Green play-all bar text (album/artist name) |
| `.nowPlayingTitle` | Sans | 700 | 26pt | Now Playing track title only |
| `.listTitle` | Sans | 700 | 16pt | Track titles, album titles, artist names in rows |
| `.listTitleMedium` | Sans | 500 | 16pt | Non-emphasized row title (Album Detail track list) |
| `.body` | Sans | 400 | 18pt | Lyric lines, general body |
| `.subtitle` | Sans | 400 | 14pt | Artist line under album title in a row |
| `.subtitleItalic` | Sans italic | 400 | 14pt | Album reference in a song row subtitle |
| `.metadata` | Mono | 400 | 12pt | Metadata strips (year · tracks · duration), context rows |
| `.timestamp` | Mono | 400 | 13pt | Scrubber times, track durations in rows |
| `.tabLabel` | Mono | 700 | 10pt | Tab bar labels |
| `.inversionLabel` | Mono | 700 | 10pt | Label column in navy metadata zones |
| `.trackNumber` | Mono | 400 | 13pt | Track numbers in Album Detail / Queue list |

---

## 4. Component primitives

Every interactive element follows the **brutalist primitive pattern**:

1. Fill color (white default, or semantic color for state)
2. 2px solid black stroke (`stroke="#000000" stroke-width="2"`)
3. Offset navy shadow: a same-sized rect filled `#004D70`, positioned behind-and-below-left
4. No blur, no gradient, no corner rounding

### Shadow offset sizes

| Element scale | Offset |
|---|---|
| Small (44×44 buttons, 44-tall bars, tabs, filter chips) | **4px** (shadow at `x-4, y+4`) |
| Medium & large (play-all bar, yellow section blocks, Now Playing play button 82×82, album thumbnails 64×64) | **6px** (shadow at `x-6, y+6`) |

### Album art shadow

None. Album art renders with a 2px black stroke only, no offset shadow. Art is content, not a control — shadows are reserved for interactive primitives (buttons, bars, blocks, tabs). The stroke provides sufficient containment.

### Album art sizing

Album art renders at **full available width** (device width minus 24px padding on each side) in all primary views: Now Playing, Album Detail. The art is always square. This makes the artwork the dominant visual element of the view.

In list contexts (Artist Detail album rows, Library album grid, Search results), art renders at fixed thumbnail sizes (64×64 in album rows, grid-appropriate in Library) per §5.6.

### Active / inverted state (overrides the primitive)

When an element is in the "currently active" state:
- Fill becomes `ampNavy` (`#004D70`)
- Content (icons, text) becomes white
- **Shadow is removed** — the navy itself is the depth
- 2px stroke remains

Applies to: selected tab, currently-playing row, active BT button, active loop toggle, selected filter chip, current lyric line, liked-track heart button.

### Soft cap

Max ~4 navy inversions per view before the "active" signal dilutes. If you need more, one of them isn't really active.

---

## 5. Named components

### 5.1 Back button
- 44×44, white fill, 4px shadow, 2px stroke
- Content: left-pointing chevron, `stroke-width="2.5"`, round linecaps/linejoins
- Chevron path: three points forming `<` — e.g., right-top, middle-left, right-bottom, roughly 14px wide × 22px tall, centered
- Behavior: pops the current view off the navigation stack

### 5.2 Play-all bar *(new primitive)*
- Height 44, fill `ampGreen`, 2px stroke, 6px shadow
- Variable width (256 in the 360-wide frame, sitting in the chrome row next to the back button)
- Content: `.playAllBarTitle` text left-aligned with 16px inset + black right-pointing play triangle at right edge (14px-ish wide, vertically centered)
- Behavior: tap plays the entity (album / artist / playlist) from track 1; **long-press → shuffle-play** (starts the entity in shuffled order)
- Live in: Album Detail chrome, Artist Detail chrome, Playlist Detail chrome

### 5.3 View title block (yellow)
- Height 44, fill `ampYellow`, 2px stroke, 6px shadow
- Typically 324 wide (24 px outside padding × 2 from the 360 frame)
- Content: `.viewTitle` left-aligned with 16px inset
- Not tappable
- Used as: view-level title in tab roots (LIBRARY, QUEUE, Lyrics), section headers in Album/Artist Detail (Tracks, Albums, Songs), Search section dividers (Artists, Albums, Songs)

### 5.4 Track row (list cell)
Two variants:

**Regular** (44–48 tall):
- Track number right-aligned at x≈36, `.trackNumber` muted
- Title at x=56, `.listTitleMedium`
- Duration right-aligned at right edge, `.timestamp` muted
- 1px `ampDivider` at the bottom edge

**Navy-inverted** (60–64 tall, currently playing):
- Full-width `ampNavy` fill, no stroke, no shadow
- 3 white equalizer bars at left (replacing the track number):
  - Bar 1: 4×20, Bar 2: 4×26, Bar 3: 4×16, 3px gap each
  - In a real SwiftUI build these animate (sine-staggered height)
- Title at x=56, `.listTitle` (bold), white
- Duration right-aligned, `.timestamp`, white
- No divider lines adjacent to an inverted row

### 5.5 Song result row (Search / Artist Detail)
- 60 tall
- Title at x=24, baseline ≈ row_top+20, `.listTitle`
- Subtitle at x=24, baseline ≈ row_top+40, `.subtitle`:
  `{Artist}  ·  <tspan italic>{Album}</tspan>`
- Duration right-aligned, `.timestamp` muted
- 1px divider at the bottom edge

### 5.6 Album row (Artist Detail / Library Albums)
- 80 tall
- 64×64 thumbnail at x=24, y=row_top+8, 4px shadow, 2px stroke. Falls back to a solid `ampNavy` block with the first letter if art is missing.
- Title at x=104, baseline ≈ row_top+28, `.listTitle`
- Meta at x=104, baseline ≈ row_top+52, `.metadata` muted: `{Year}  ·  {Track count} tracks`
- 1px divider at the bottom edge

### 5.7 Artist row (Library Artists)
- 48 tall
- Name at x=24, baseline ≈ row_top+30, `.listTitle`
- Meta at right edge, `.metadata` muted: `{Album count} albums`
- 1px divider at the bottom edge

### 5.8 Filter chip
- Width variable (based on label), height 32–36, 4px shadow
- White fill + black text when unselected; navy fill + white text when selected
- Mono bold uppercase label
- Used in Library (Albums / Artists / Playlists switcher)

### 5.9 Tab bar tab
- 72×56, 4px shadow, 2px stroke
- Unselected: white fill, black icon and label
- Selected: navy fill, white icon and label, no shadow
- Icon stacked above label: icon in upper ~32px, `.tabLabel` at baseline y≈48

### 5.10 Transport buttons
All with 2px stroke:

| Button | Size | Shadow | Default | Active state |
|---|---|---|---|---|
| Bluetooth | 44×44 | 4px | white fill | navy inversion when a BT device is connected |
| Previous | 56×56 | 4px | white fill | N/A (momentary) |
| Play / Pause | 82×82 | 6px | `ampGreen` fill, black triangle or two black bars | same — not inverted |
| Next | 56×56 | 4px | white fill | N/A |
| Loop | 44×44 | 4px | white fill | navy inversion when loop is on |

Icon specs:
- Play: right-pointing black triangle, ~20px tall, centered
- Pause: two black bars 9×34, centered with 10px gap
- Prev/Next: black vertical bar + triangle pointing respectively left/right
- BT: standard Bluetooth glyph (two overlapping triangles on a vertical axis), white when inverted
- Loop: circular arrow with arrowhead, 2.5px stroke

### 5.11 Lyrics button
- White fill, 4px shadow, 2px stroke
- Height 44, width flexible (shares a row with the like button — see §5.15)
- Icon: 3 stacked black lines (14, 20, 12 px long) + "Lyrics" label in `.listTitle`
- Behavior: pushes the Lyrics view
- Only shown when `Settings.showLyricsButton == true` (default ON)
- When hidden (setting OFF), the like button (§5.15) centers itself in the row

### 5.12 Scrubber
- Full width within 24px padding each side (so 312 wide in a 360 frame)
- Background track: 4px tall, `ampDivider` fill
- Progress fill: `ampGreen`, width = `duration * progress`
- Playhead: 16×16 circle, `ampGreen` fill, 2px black stroke, centered on progress edge
- Below the scrubber: current time left-aligned (`.timestamp` muted), remaining time right-aligned with leading `-` (e.g., `-3:27`)

### 5.13 Search input
- Height 48 (taller than 44 to accommodate larger text), white fill, 4px shadow, 2px stroke
- Magnifying glass glyph at x=14, 2px stroke, 8px radius
- Text input area from x=40 to x=-44 (right edge minus clear button)
- Right side: `×` clear button when text is present. Search happens on type — no submit button needed.

### 5.14 Text link (quiet destructive / utility action)
- No button chrome — just mono bold uppercase muted text
- Example: "CLEAR RECENT" at the bottom of the search recent list
- Smaller tap target OK for non-primary destructive actions; but wrap in a tappable 44-tall hit zone

### 5.15 Like button (heart)
- 44×44, 4px shadow, 2px stroke
- **Unliked state:** white fill, black heart outline (2px stroke, no fill)
- **Liked state:** navy inversion — navy fill, white solid heart
- Behavior: tap toggles the current track's liked status. Liked tracks are persisted locally in amp (see §9.1).
- Position: in the Now Playing action row, to the **right** of the Lyrics button. The two buttons share a centered row below the transport. If the Lyrics button is hidden (setting OFF), the like button centers itself alone.
- The heart icon should be visually simple: a standard heart glyph, ~18px wide, centered in the 44×44 hit zone.

---

## 6. Tab bar (persistent)

**Order left-to-right: LIBRARY / SEARCH / QUEUE / ACTIVE**

Rationale: [Library, Search] grouped on the left as "find music," [Queue, Active] grouped on the right as "playback state." Active at the rightmost matches iOS convention for "now playing" and puts the most common return-to-Now-Playing tap in the right-thumb zone.

Icons:
- **LIBRARY** — 3 horizontal lines of equal length (28px), stacked with 7px gap
- **SEARCH** — circle (r=8) + angled handle line from (38,26) to (44,32)
- **QUEUE** — 3 dots (r=1.8) on the left + 3 lines of equal length to their right
- **ACTIVE** — right-pointing play triangle (14×16)

Selected tab uses navy inversion.

When a detail view is pushed from a tab, the originating tab stays selected. When a tab is tapped while already on its root, the view scrolls to top.

---

## 7. View specifications

### 7.1 Library (tab root)

**Chrome:**
- Yellow `LIBRARY` view title block
- Two 44×44 icons in the chrome row: **gear icon** for Settings, **search icon** for jumping to the SEARCH tab. Both use the standard white brutalist button with 4px navy shadow. Placement (left vs. right) is implementer's call.

**Filter chip row** below the header: `Albums` / `Artists` / `Playlists`. Selected chip uses navy inversion.

**Content area** switches based on the selected chip:

- **Albums** (default): 2-column grid of album thumbnails (aspect square, 2px stroke, no shadow — art is content per §4), with title + artist caption below each. Tap → pushes Album Detail.
- **Artists**: list of artist rows (§5.7). Tap → pushes Artist Detail.
- **Playlists**: list of playlist rows sorted alphabetically. If no playlists exist, show plain centered text: *"No playlists found."* **Playlists are read-only in amp** — they display imported iTunes playlists and let you play them, nothing else.

### 7.2 Search (tab root)

**Chrome:** search input (§5.13) at the top, full-width minus 24px side padding.

**Content states:**

- **Empty (first open):** brief hint text centered, e.g., *"Search your library."*
- **With recent searches:** yellow `RECENT` block header + list of recent query rows (each just the query text in `.listTitle`) + `CLEAR RECENT` text link (§5.14) at the bottom of the list.
- **Results (query typed):** grouped by type in yellow section blocks:
  - `Artists` — artist result rows (name only)
  - `Albums` — album result rows (title + artist)
  - `Songs` — song result rows (title + `{Artist} · {Album italic}` subtitle + duration)
- Tap artist → push Artist Detail
- Tap album → push Album Detail
- Tap song → start playback (no navigation)

### 7.3 Queue (tab root)

**Chrome:** yellow `QUEUE` view title block with track count, e.g., `Queue · 12 tracks` (count mono-regular on the right end of the block).

**Content:** list of track rows (§5.4) with position numbers (1, 2, 3…). Current track rendered as the navy-inverted variant with equalizer bars replacing the position number. Scrolled so the current track is visible on initial load.

**Footer strip** (below the list, before the tab bar): small mono muted text, e.g., `PLAYING FROM Kid A`.

**Scroll behavior:** see §8.4 for the sticky currently-playing row and blue overflow bar interaction.

### 7.4 Album Detail (pushed view)

**Chrome:** back button + play-all bar with the album name.

**Hero:** full-width album art (device width minus 48px padding), square. 2px stroke, no shadow. Tappable to flip (§8.1).

**Info strip:** centered below the art:
- Artist name (`.listTitle`, sans regular 18pt)
- Meta line (`.metadata` muted): `{Year}  ·  {Track count} tracks  ·  {Total duration}`

**Yellow `Tracks` block.**

**Track list:** §5.4 rows. Currently-playing track (if it's in this album) rendered navy-inverted.

### 7.5 Artist Detail (pushed view)

**Chrome:** back button + play-all bar with the artist name.

**Yellow `Albums` block** + album rows (§5.6).

**Yellow `Songs` block** + song rows (§5.5). This can be a long list; the whole view scrolls.

Tap album row → push Album Detail. Tap song row → start playback.

### 7.6 Now Playing (Active tab root)

**No back button.** Now Playing is the root view of the Active tab; there is nothing to navigate back to. The album art sits at the top of the view with no chrome above it (just the iOS status bar).

**Hero:** full-width album art (device width minus 48px padding), square. 2px stroke, no shadow. Tappable to flip (§8.1).

**Info strip:** left-aligned (24 inset):
- Title (`.nowPlayingTitle`)
- Artist (`.listTitle` regular)
- Meta (`.metadata` muted): `From {Album}  ·  {Year}`

**Scrubber + times** (§5.12)

**Transport row** (§5.10): BT · Prev · Play/Pause · Next · Loop. Shuffle is **not** present here.

**Action row** below the transport, centered:
- **Lyrics button** (§5.11) on the left
- **Like button** (§5.15) on the right
- If the Lyrics button is hidden (setting OFF), the like button centers itself alone.

**No Track Info button** — track info is accessed via the album-art flip (§8.1).

### 7.7 Lyrics (pushed view from Now Playing)

**Chrome:** back button only.

**Yellow `Lyrics` block.**

**Context row** below the block, centered, `.metadata` muted: `{Track}  ·  {Artist}  ·  {Album}`.

**Body:** scrollable list of lyric lines, each 44 tall, text centered horizontally, `.body` 18pt sans medium, color `ampBlack`.

**Synced current line:** when the track has time-synced lyrics and we're on a specific line, that line is rendered as a full-width `ampNavy` strip (no stroke, no shadow) with white bold text (`.body` at weight 700). The view auto-scrolls to keep the current line visible (centered vertically in the body area).

**Unsynced lyrics:** no line is ever inverted; no auto-scroll; user scrolls manually. All lines render plain.

### 7.8 Playlist Detail (pushed view)

Mirrors Album Detail (§7.4) with these differences:

- **Play-all bar** shows the playlist name.
- **Album art area** shows a **2×2 grid collage** of the first four unique album covers in the playlist (each quadrant is a square, 2px black stroke between them, outer 2px stroke, no shadow). If fewer than 4 unique albums, repeat covers to fill. If the playlist has dedicated artwork in iTunes metadata, use that instead of the collage.
- **Track rows show artist on each row** — unlike Album Detail where the artist is shared, playlist tracks come from multiple artists. Each row adds the artist name in `.subtitle` muted below the track title.
- **No "Tracks" yellow block** — use the playlist's track count in the meta line instead, matching Album Detail's pattern.

### 7.9 Settings (pushed view from Library chrome)

Accessed via the gear icon in Library's chrome row.

**Chrome:** back button only.

**Yellow `SETTINGS` view title block.**

**Toggles:**
- `Show lyrics button when available` — default ON. Toggle primitive: brutalist 44-tall row. When OFF, white box with text label. When ON, navy-inverted treatment to indicate active.

**Export section:**

Yellow `EXPORT` section block.

- `Export liked tracks as .m3u` — a white brutalist button (44-tall, 4px shadow). Tap exports all liked tracks as a `.m3u` playlist file via the iOS share sheet. If no liked tracks exist, the button is present but shows a brief inline message on tap: *"No liked tracks to export."*

---

## 8. Interactions

### 8.1 Album art tap-to-flip
- **Trigger:** single tap on the album art (Now Playing or Album Detail)
- **Animation:** 3D Y-axis rotation, ~400ms, ease-in-out
- **Front:** album artwork (loaded from iTunes metadata; fallback to `ampNavy` square with album initial in white sans bold if missing)
- **Back:** `ampNavy` fill, metadata in 2-column layout:
  - Labels column at left (16px inset), `.inversionLabel`, color `ampInversionLabel`
  - Values column at x=74 (or 64px from the label left), `.listTitle` but 12pt, white
  - Baselines spaced ~26px apart
  - **Rows (always shown):** `ALBUM`, `YEAR`, `GENRE`, `TRACK` (`{n} of {m}`), `FORMAT` (e.g., `FLAC 320 kbps`)
  - **Rows (conditional — shown only if present in metadata):** `COMPOSER`, `CONDUCTOR`
  - When conditional rows are hidden, the visible rows center vertically within the art square
- **Tap again:** flips back to the art
- **SwiftUI:** `rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))` with a back face drawn at 180° initial rotation and hidden via `.opacity` based on angle

The art tap gesture is **reserved for this interaction**. Pause/play is only via the transport button; there is no tap-anywhere-to-pause.

### 8.2 Navigation
- Tap album in Library / Search / Artist Detail → **push** Album Detail
- Tap artist in Search → **push** Artist Detail
- Tap song in Search or Artist Detail → starts playback (no nav)
- Tap Lyrics button in Now Playing → **push** Lyrics view
- Tap track in Queue → jump playback to that track (in-place)
- Tap track in Album Detail → start playback from that track
- Tap play-all bar → play the album / artist / playlist from track 1
- Long-press play-all bar → shuffle-play the album / artist / playlist
- Long-press track row (in Queue, Search, Album Detail) → **push** Album Detail for that track's album
- Tap Back in any chrome → pop the current view
- Tap a tab → if on a different tab, switch; if on this tab's root, scroll to top; if on a pushed view within this tab, pop all the way back to the root
- Tap gear icon in Library chrome → **push** Settings
- Tap search icon in Library chrome → switch to SEARCH tab
- Tap like button in Now Playing → toggle liked status (in-place)

### 8.3 Equalizer bars animation
- 3 vertical white bars (4px wide each)
- Heights oscillate between ~8 and ~28px on a staggered sine wave (different phase per bar)
- Period ~1.2s
- Static in mockups (hardcoded heights), animated in real app via SwiftUI `TimelineView` or `withAnimation`

### 8.4 Queue scroll behavior

The currently-playing row and the blue overflow bars are independent systems that share edge space:

**Blue overflow bars** are fixed overlays at the top and bottom edges of the Queue content area. Each appears only when content is clipped beyond that edge. They are a gradient from the current implementation's blue tone to transparent, roughly 8–12px tall, layered over the content. They indicate "scroll to see more" and nothing else.

**Pinned currently-playing row** acts as a **viewport boundary** when pinned. The currently-playing row replaces the blue bar at whichever edge it pins to — they are never both visible on the same edge. Three states:

1. **Track visible in viewport:** row sits in its natural list position. Blue overflow bars appear at top and/or bottom edges if content is clipped beyond either edge. Standard scroll behavior.

2. **Scrolled past the track (looking ahead):** row pins to the top of the content area (below the Queue header). The pinned row replaces the top blue bar — no blue bar appears at the top edge while the row is pinned there. A bottom blue bar appears if content is clipped below.

3. **Scrolled before the track (looking back):** row pins to the bottom of the content area (above the tab bar). The pinned row replaces the bottom blue bar — no blue bar appears at the bottom edge while the row is pinned there. A top blue bar appears if content is clipped above.

The pinned row retains its full navy-inversion treatment with equalizer bars and uses pure sticky positioning (no snap animation). Content scrolls beneath it. On track change, the queue repositions so the new currently-playing track is visible in the viewport (unpinned), and the previous track reverts to a regular numbered row.

### 8.5 Alphabetic scrubber

Long lists (Library › Artists, Library › Albums when sorted alphabetically) display an alphabetic scrubber rail on the right edge. Uses iOS's native `SectionIndexTitles` behavior. When the user drags along the scrubber rail, display a **large letter indicator** — a 72×72 white brutalist box (2px stroke, 4px navy shadow) centered on screen with the current letter in `.viewTitle` (mono bold 22pt, black). The indicator dismisses ~300ms after the user lifts their finger.

---

## 9. iTunes sync constraints

**amp is a player, not a library manager.** When a user syncs their iTunes library to their device, iTunes overwrites the library state on device. Any changes amp makes to the library are lost on next sync.

This drives several product decisions:

- **No "Add to playlist"** — amp cannot write playlist membership; iTunes would overwrite it on next sync
- **No smart playlist creation** — amp cannot create smart playlists that survive a sync
- **Playlists in amp are read-only** — they display imported playlists and let you play them, nothing else
- **No library editing at all** — no rating changes, no play count changes, no metadata edits

If in doubt: **does this action write to the music library?** If yes, amp doesn't do it.

### 9.1 Liked tracks (local-only persistence)

The one exception to the "no local state" rule is **liked tracks**. When a user taps the heart button (§5.15) in Now Playing, that track's liked status is persisted locally inside amp's own data store (not written back to iTunes). Liked tracks survive app restarts but are **not** synced to iTunes — they live entirely within amp.

Liked tracks can be exported as a `.m3u` playlist file from Settings (§7.9). This is the primary use case: the user likes tracks as they listen, then exports a playlist they can import into iTunes or another player.

The data model is minimal: a set of track identifiers (persistent IDs from the iTunes library) stored locally. No additional metadata beyond the ID — the track's title, artist, album, etc. are always read from the library at display time.

---

## 10. Accessibility

- All interactive elements meet or exceed the 44×44 iOS minimum tap target
- Every color-coded state is reinforced with a **non-color indicator**:
  - Currently-playing row: navy inversion + 3 animated equalizer bars (not just color)
  - Active BT / loop: navy inversion + white glyph (shape differs from inactive)
  - Playable element: green fill + play triangle glyph (shape signals playability)
  - Selected tab: navy inversion (visible even in grayscale)
  - Liked track: navy inversion + filled heart (vs outlined heart when unliked)
- Yellow is never used as foreground text color — contrast on white is 1.4:1 which fails even Large Text AA
- All body text ≥ 12pt; reading text (lyrics, titles) ≥ 16pt
- Font choice: Atkinson Hyperlegible is specifically designed for low-vision legibility
- VoiceOver labels: each primitive should ship with a meaningful `.accessibilityLabel` — e.g.:
  - Play-all bar: *"Play all of {album name} by {artist}"*
  - Like button: *"Like {track name}"* / *"Unlike {track name}"*
  - Long-press hint on play-all bar: *"Shuffle play"*

---

## 11. SwiftUI implementation notes

Suggested structure (high-level; Claude Code may refine):

```
Theme/
  Colors.swift           // Color tokens (§2)
  Fonts.swift            // Typography tokens (§3)

Components/
  BackButton.swift       // §5.1
  PlayAllBar.swift       // §5.2 (tap + long-press)
  ViewTitleBlock.swift   // §5.3
  TrackRow.swift         // §5.4 (both variants)
  SongResultRow.swift    // §5.5
  AlbumRow.swift         // §5.6
  ArtistRow.swift        // §5.7
  FilterChip.swift       // §5.8
  TabBarTab.swift        // §5.9
  TransportButton.swift  // §5.10 (parameterized)
  LyricsButton.swift     // §5.11
  Scrubber.swift         // §5.12
  SearchInput.swift      // §5.13
  LikeButton.swift       // §5.15
  BrutalistShadow.swift  // shared modifier for the 4px / 6px offset shadow

Views/
  LibraryView.swift
  SearchView.swift
  QueueView.swift
  NowPlayingView.swift
  AlbumDetailView.swift
  ArtistDetailView.swift
  PlaylistDetailView.swift
  LyricsView.swift
  SettingsView.swift
  AlbumArtView.swift     // with the flip interaction (§8.1)

Services/               // existing, unchanged except LikedTracksService
  AudioPlayerService
  QueueManagerService
  LibraryService
  LikedTracksService     // NEW — local persistence for liked track IDs + .m3u export
```

**The brutalist shadow modifier** is worth implementing once and reusing:

```swift
struct BrutalistShadow: ViewModifier {
    let offset: CGFloat  // 4 or 6
    let shadowColor: Color = Color.ampNavy
    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(shadowColor)
                .offset(x: -offset, y: offset)
            content
        }
    }
}
```

Use with: `.modifier(BrutalistShadow(offset: 4))` on any primitive except the active/inverted state (which has no shadow).

**The 2px black stroke** should similarly be a modifier or a consistent `.overlay(Rectangle().stroke(Color.black, lineWidth: 2))` pattern.

**LikedTracksService** manages the set of liked track persistent IDs. Storage: `UserDefaults` for simplicity (it's just a `Set<MPMediaEntityPersistentID>`), or a small SQLite/SwiftData store if the set grows large. Exposes: `isLiked(trackID:) -> Bool`, `toggleLike(trackID:)`, `allLikedTrackIDs() -> Set<...>`, `exportAsM3U() -> URL`.

**The service layer otherwise does not change** as part of this redesign. All other changes are in the View layer and in the Theme tokens.

---

## 12. What's being removed (migration list)

Remove from the existing codebase:

- All references to lime green `#BED52F` → replace with `ampGreen` where playable, `ampYellow` where organizational header, or remove entirely where decorative
- Pink `#EA7586` currently-playing highlight → replace with the navy-inversion row variant
- `TrackInfoButton` (or equivalent) in Now Playing → delete; the behavior moves to `AlbumArtView`'s tap gesture
- `ShuffleButton` in Now Playing transport → delete from the Now Playing transport row; shuffle is accessed via long-press on play-all bar in Album / Artist / Playlist Detail
- Circular tab bar tabs with blue shadows → replace with the square 72×56 tabs in §5.9
- The separate yellow search-submit button next to the search input → delete; search happens on type
- Back button in Now Playing (Active tab root) → delete; Now Playing is a tab root with no parent to navigate back to

Rename tabs:
- `Mixes` → `LIBRARY`
- `Active` remains
- `Queue` remains
- `Search` remains

New order (replacing current `Mixes / Queue / Search / Active`): **`LIBRARY / SEARCH / QUEUE / ACTIVE`**

---

## 13. Empty states

All empty states use centered mono muted text, no other decoration:

| View | Copy |
|---|---|
| Library (no music) | `No music found.` |
| Library › Playlists (no playlists) | `No playlists found.` |
| Search (no results) | `No results found.` |
| Queue (nothing queued) | `Queue is empty.` |
| Lyrics (no lyrics available) | `No lyrics available.` |

---

## 14. Reference mockups

All mockups use a 360-wide frame simulating an iPhone content area (the real app fills the full device width minus safe areas).

The following views have been mocked in the brutalist design language and should be treated as normative for layout, spacing, and hierarchy (exact pixel positions may be re-derived from the spec above):

- Now Playing (default album art + flipped album art states, with action row: Lyrics + Like)
- Album Detail (with play-all bar)
- Artist Detail (with play-all bar, 64px album thumbnails)
- Lyrics view (with current-line navy inversion)
- Search (empty, recent, results states)
- Queue (with currently-playing navy inversion, equalizer bars, position numbers, sticky row behavior)
- Library (album grid with filter chips, gear + search icons in chrome)
- Settings (toggle + export)

Mockups are SVG; pixel positions within them are illustrative, not prescriptive. The spec above is the source of truth.

---

*End of spec.*
