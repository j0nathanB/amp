# App Expansion — Discussion Notes

Exploratory notes from a conversation on 2026-04-24. **Not a plan** — just captures the option space and tradeoffs so we can decide later. The detailed implementation work for the local-folder vector already lives in `LOCAL_LIBRARY_PLAN.md`; this doc records the *broader* surface and the architectural options we considered.

## Current state (verified 2026-04-24)

Every track URL in the app today comes from `MPMediaQuery.songs()` returning an `MPMediaItem.assetURL` (`PlaybackEngineService.swift:482-495`). `Song.id` is `MPMediaEntityPersistentID` (`UInt64`) and that ID is the spine of every persistence layer (queue, liked tracks, search index, artwork cache).

Decoder side: `playerNode.scheduleSegment(audioFile, ...)` with `AVAudioFile(forReading: url)` (`PlaybackEngineService.swift:390-424`). This handles MP3, AAC, ALAC, WAV, AIFF, FLAC (iOS 15+), Opus natively — no decoder changes needed for any non-OGG format. The format question is moot in practice today because Apple's sync tooling won't put FLAC into the iOS Music Library; the decoder *can* play FLAC, but no FLAC files ever reach it.

## Three expansion vectors

### 1. Local folder import (Files app, iCloud Drive)

**Status:** designed. See `LOCAL_LIBRARY_PLAN.md`.

**Effort:** 11–15 days across 6 phases.

**Side benefit:** unlocks FLAC playback for free, since FLAC files reach the engine via a non-MPMediaQuery path. Format matrix in plan §Phase 5.

### 2. Remote URLs (Plex / Subsonic / Jellyfin / HTTP streams)

**Status:** unscoped. Currently zero `URLSession` for media; no auth layer; no streaming.

**Engine implication:** `AVAudioPlayerNode.scheduleSegment` is buffer-based and assumes a complete local file. Remote streaming wants `AVPlayer` (HLS-aware) or `AVAudioEngine` with chunked `URLSession` downloads scheduled as buffers. This is a meaningfully different playback path from what exists today — bigger than the local-folder change.

**Auth/metadata implication:** every server protocol (Plex, Subsonic API, Jellyfin) has a different auth flow, library-listing API, and metadata schema. v1 should pick one (Subsonic API is the most widely adopted "music server" protocol — Navidrome, Airsonic, Funkwhale, etc., all speak it).

**Architectural fit:** the same `TrackID` enum from the local-folder plan extends naturally — add `case remote(serverID: UUID, trackID: String)`. The hard part isn't the model, it's the streaming engine and the per-server adapter.

**Estimated effort:** comparable to or larger than local-folder. Would not start without (1) landing first.

### 3. OGG / Vorbis support

**Status:** out of scope. iOS has no native Vorbis decoder; would require shipping a third-party codec (e.g. `libvorbis` via SPM). Niche enough to defer indefinitely unless a user explicitly asks.

## ID architecture — three options considered

The local-folder plan commits to **option (1) sum-type** without showing the alternatives. Recording them here for completeness in case we revisit:

### (1) Sum-type `TrackID` — chosen by `LOCAL_LIBRARY_PLAN.md`

```swift
enum TrackID: Hashable, Codable {
    case mediaLibrary(MPMediaEntityPersistentID)
    case localFile(LocalTrackID)
    // future: case remote(serverID: UUID, trackID: String)
}
```

**Pros:** compiler enforces source-awareness at every callsite that pattern-matches. Future expansion (remote, podcasts, etc.) drops in cleanly. Type system catches "I forgot to handle local tracks here" bugs at compile time.

**Cons:** large mechanical refactor (17 files in Phase 1). All persistence formats need version bumps + migration paths. ~5% size tax on queue/cache files from enum case discriminators.

### (2) Synthetic `UInt64` in a reserved range — *not* chosen

Mint imported-track IDs with the high bit set (`0x8000_0000_0000_0000+`); Apple's random IDs almost never land there. One dispatch point in `getAudioURL` checks the bit and routes to either `MPMediaQuery` or the bookmark store.

**Pros:** few files touched (just URL/artwork resolution). No persistence migration — `UInt64` stays `UInt64` everywhere. Persistence formats stay version-stable. Days of work, not weeks.

**Cons:** convention-based — nothing in the type system stops someone from passing an imported ID to `MPMediaQuery` (returns nil, no compile error). Doesn't extend cleanly to a third source (remote streams need their own ID space too). Contains an implicit assumption that Apple's IDs really are random `UInt64`s; if Apple ever changes that, the high-bit scheme breaks silently.

**Verdict:** would be the right call if the local-folder feature were small and isolated. Since (1) is already designed and the broader expansion surface (remote sources, etc.) is a real possibility, the type-safety argument wins.

### (3) Parallel `ImportedSong` struct alongside `Song`

Keep `Song` MPMediaItem-bound; add a separate `ImportedSong` model with its own UUID. Library/search/queue views render both via a shared `TrackProtocol` or duplicated code paths.

**Pros:** zero impact on existing code paths. Each source has a clean independent model.

**Cons:** doubles UI surface area — every list, search result, queue row, detail view needs a "is this one or the other?" branch. Heterogeneous queues become awkward (`[any TrackProtocol]` with type erasure). Hardest to maintain long-term as features grow.

**Verdict:** rejected. The local-folder plan §Architectural decision lays out why merging beats parallel — same five services would need to know about both source types regardless.

## What to revisit later

- Do we want to ship vector (1) before opening conversation about (2)? Probably yes — local-folder is concrete, requested, and unlocks FLAC. Remote-server support is more speculative and the engine change is bigger.
- If we do (1) and then (2), the sum-type `TrackID` design from `LOCAL_LIBRARY_PLAN.md` already accommodates a third case. No re-architecting required.
- OGG/Vorbis stays parked unless someone specifically asks.

## Cross-references

- `LOCAL_LIBRARY_PLAN.md` — full implementation plan for vector (1), 6 phases, 11–15 days.
- `DataModels.swift:6-38` — current `Song` shape (`MPMediaEntityPersistentID`-keyed).
- `PlaybackEngineService.swift:385-452` — the single playback entry point that any new source needs to dispatch through.
