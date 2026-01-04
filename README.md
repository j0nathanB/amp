# amp

another music player (amp). A brutalist music player for iOS that plays your local music library.

## Features

- **Library browsing** — Browse your music by playlists, artists, and albums
- **Queue management** — Full playback queue with shuffle and loop support
- **Smart search** — Fast, diacritics-insensitive search across your library
- **Background playback** — Lock screen controls and now playing info
- **Queue persistence** — Your queue survives app restarts

## Design

amp uses a brutalist design language with bold colors, hard shadows, and clear visual hierarchy. The interface prioritizes readability with the Atkinson Hyperlegible typeface.

## Navigation & Discovery

amp is designed for exploration. You can dive into your library from multiple entry points:

**From Now Playing:**
- Tap the album art to reveal track metadata (album, artist, year, genre)
- Tap again to return to artwork

**From Search:**
- Search returns songs, artists, and albums in unified results
- Tap an **artist** to see all their albums and songs
- Tap an **album** to see artwork, metadata, and full track listing with disc grouping
- Tap any **song** to start playback with that song's context as the queue
- From an album view, tap Play to queue the entire album starting from track 1
- From an album's track list, tap any track to start from that position

**From Queue:**
- Tap any track to jump to it
- The currently playing track is highlighted

This means you can hear a random song, tap the artwork to see what album it's from, search for that album, and load the whole thing — all without leaving the app's flow.

## Requirements

- iOS 18.5+
- Xcode 16+
- A device with music in your local library (Apple Music library access required)

## Installation

### Building from Source

1. Clone the repository
2. Open `amp.xcodeproj` in Xcode
3. Select your development team in Signing & Capabilities
4. Build and run on your device

```bash
# Or build from command line
cd amp
xcodebuild -scheme amp -destination 'generic/platform=iOS' build
```

### Installing on Your Device

**Option 1: Xcode (Recommended for Development)**

1. Connect your iPhone via USB
2. Open the project in Xcode
3. Select your device from the device picker
4. Click Run (⌘R)

Your device must be registered in your Apple Developer account. Free accounts can run apps for 7 days before re-signing.

**Option 2: Personal Automation**

For longer-term installation without TestFlight:

1. Archive the app in Xcode (Product → Archive)
2. Export for Ad Hoc or Development distribution
3. Install via Apple Configurator 2 or Xcode's Devices window

## Screenshots

*Screenshots coming soon*

## Architecture

amp follows a service-oriented architecture with clear separation of concerns:

```
┌─────────────────────────────────────────────────────────┐
│                      UI Layer                           │
│  NowPlayingView · QueueView · SearchView · PlaylistsView│
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│                 AudioPlayerService                      │
│            (Orchestrator / Public API)                  │
└────┬──────────────────┬─────────────────────┬───────────┘
     │                  │                     │
┌────▼─────┐     ┌──────▼──────┐      ┌───────▼───────┐
│Playback  │     │   Queue     │      │  Navigation   │
│Engine    │     │   Manager   │      │   Service     │
│Service   │     │   Service   │      │               │
└──────────┘     └─────────────┘      └───────────────┘
```

**Core Services:**
- `AudioPlayerService` — Main orchestrator, provides unified API for UI
- `PlaybackEngineService` — AVAudioPlayer operations, audio session, now playing info  
- `QueueManagerService` — Queue state, persistence, shuffle logic
- `NavigationService` — UI navigation state and tab selection
- `LibraryService` — Music library access with optimized search indexing

## Development

### Running Tests

```bash
# Unit tests
xcodebuild -scheme amp -destination 'platform=iOS Simulator,name=iPhone 16' test

# UI tests
xcodebuild -scheme ampUITests -destination 'platform=iOS Simulator,name=iPhone 16' test
```

### Project Structure

```
amp/
├── Services/
│   ├── AudioPlayerService.swift
│   ├── PlaybackEngineService.swift
│   ├── QueueManagerService.swift
│   ├── NavigationService.swift
│   └── LibraryService.swift
├── Views/
│   ├── NowPlayingView.swift
│   ├── QueueView.swift
│   ├── SearchView.swift
│   ├── PlaylistsView.swift
│   └── MainTabView.swift
├── Models/
│   ├── DataModels.swift
│   ├── PlaybackQueue.swift
│   └── Theme.swift
└── ampApp.swift
```

## Roadmap

- [ ] Queue reordering and track removal
- [ ] FLAC and local folder access
- [ ] Recently played / most played tracking
- [ ] Add song to queue (add to next/add to end)
- [ ] Genres in search
- [ ] Colors

## License

This project is licensed under the GNU General Public License v2.0 - see [LICENSE](https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt) for details.

---

Built with SwiftUI and the MediaPlayer framework.
