# iPhone Music App - Project Context

## Project Overview
SwiftUI-based music player app for iPhone, currently in MVP state. The app allows users to browse their music library, create queues, and play audio. Currently requires significant refactoring to address architectural issues and performance problems.

## Tech Stack
- **Framework**: SwiftUI
- **Audio**: MediaPlayer framework (MPMediaItem, MPMediaQuery)
- **Architecture**: MVVM with ObservableObject services
- **Platform**: iOS

## Current Architecture

### Key Files
- **AudioPlayerService.swift**: Main service handling audio playback, queue management, UI state, and persistence (currently a god object)
- **NowPlayingView.swift**: Current track display and playback controls
- **QueueView.swift**: Queue management interface
- **LibraryService.swift**: Music library search and browsing

### Current Issues
1. **Dual Queue Conflict**: App has both a main queue and lightweightQueue system causing compiler errors
2. **God Object Anti-pattern**: AudioPlayerService manages too many responsibilities (audio playback, queue state, UI navigation, persistence)
3. **Performance Bottleneck**: Library search fetches all songs/artists/albums then filters in Swift instead of using MPMediaQuery predicates
4. **Compiler Errors**: Views reference functions that no longer exist due to queue system conflicts

## Refactoring Strategy

Following a 4-phase approach:

### Phase 1: Stabilize 🛠️
- **Goal**: Fix compiler errors and get app running reliably
- **Tasks**:
  - Unify dual-queue system into single PlaybackQueue model
  - Refactor AudioPlayerService to use unified queue
  - Fix dependent views (NowPlayingView, QueueView)

### Phase 2: Optimize ⚡
- **Goal**: Fix performance bottleneck in library search
- **Tasks**:
  - Replace current search with MPMediaPropertyPredicate approach
  - Implement efficient LibraryService.search() method

### Phase 3: Decompose 🏛️
- **Goal**: Break apart the god object for better architecture
- **Tasks**:
  - Extract PlaybackEngineService (AVAudioPlayer, playback state)
  - Extract QueueManagerService (PlaybackQueue management)
  - Extract NavigationService (UI state management)
  - Update SwiftUI environment setup

### Phase 4: Iterate 🚀
- **Goal**: Establish pattern for ongoing development
- **Tasks**:
  - Use new architecture for feature development
  - Implement component-based development workflow

## Data Models
- **MPMediaItem**: Represents individual songs from user's library
- **MPMediaItemCollection**: Represents albums/playlists
- **PlaybackQueue**: Custom model for managing playback order and history

## Working Notes

### Current Phase: [Update as you progress]

### Completed Tasks:
- [ ] Set up Claude Code environment
- [ ] Create project documentation

### Next Steps:
- [ ] Begin Phase 1: Stabilize the queue system
- [ ] Define unified PlaybackQueue structure
- [ ] Refactor AudioPlayerService

### Notes:
- Working solo, can move quickly with changes
- Project is in git for safe experimentation
- Focus on getting compiler errors resolved first, then optimize

---

*This document should be updated as the project evolves and new context becomes relevant.*