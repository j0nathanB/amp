# iPhone Music App - Project Context

## Project Overview
SwiftUI-based music player app for iPhone with clean service-oriented architecture. The app provides music library browsing, queue management, and audio playback with optimized search and responsive UI.

## Tech Stack
- **Framework**: SwiftUI
- **Audio**: MediaPlayer framework (MPMediaItem, MPMediaQuery), AVAudioPlayer
- **Architecture**: Service-oriented with delegation and Combine bindings
- **Patterns**: MVVM, Singleton services, Lazy loading, Async operations
- **Platform**: iOS

## Current Architecture

### Service Layer
- **AudioPlayerService.swift**: Orchestrating service that coordinates all other services, maintains same public API as original
- **PlaybackEngineService.swift**: Pure audio playback control (AVAudioPlayer, audio session, now playing info)
- **QueueManagerService.swift**: Queue state management and persistence (PlaybackQueue, track navigation)
- **NavigationService.swift**: UI navigation state management (tab selection)
- **LibraryService.swift**: Music library search with hybrid dictionary + scan indexing

### UI Layer
- **NowPlayingView.swift**: Current track display and playbook controls
- **QueueView.swift**: Queue management with lazy loading and scroll optimization
- **PlaylistsView.swift**: Library browsing and playlist selection
- **SearchView.swift**: Search interface with diacritics-insensitive matching

### Data Models
- **PlaybackQueue.swift**: Queue management with caching and shuffle support
- **DataModels.swift**: Core data structures (Song, Artist, Album, Tab)

## Development Phases (Completed)

### ✅ Phase 1: Stabilize 🛠️ 
**Goal**: Fix compiler errors and get app running reliably
- ✅ Unified dual-queue system into single PlaybackQueue model
- ✅ Refactored AudioPlayerService to use unified queue
- ✅ Fixed dependent views (NowPlayingView, QueueView)

### ✅ Phase 2: Optimize ⚡
**Goal**: Fix performance bottleneck in library search  
- ✅ Implemented diacritics-insensitive search with string normalization
- ✅ Built hybrid dictionary + scan search indexing
- ✅ Fixed artist search by building index from songs rather than MPMediaQuery.artists()

### ✅ Phase 3: Decompose 🏛️
**Goal**: Break apart the god object for better architecture
- ✅ Extracted PlaybackEngineService (AVAudioPlayer, audio session, now playing info)
- ✅ Extracted QueueManagerService (PlaybackQueue management, persistence) 
- ✅ Extracted NavigationService (UI navigation state)
- ✅ Created orchestrating AudioPlayerService with same public API
- ✅ Fixed async initialization to prevent main thread blocking

### 🚀 Phase 4: Iterate (Current)
**Goal**: Establish patterns for ongoing development
- 🔄 Document service architecture patterns
- 🔄 Create development guidelines for future features
- 🔄 Optimize performance with lazy loading and efficient UI updates

## Service Architecture Patterns

### 1. **Service Separation of Concerns**
- **PlaybackEngineService**: Pure audio operations (play, pause, seek, audio session)
- **QueueManagerService**: State management (queue, persistence, track navigation)  
- **NavigationService**: UI state (tab selection, navigation methods)
- **AudioPlayerService**: Orchestration (coordinates services, maintains public API)

### 2. **Communication Patterns**
- **Delegation**: Services communicate via delegate protocols (PlaybackEngineDelegate, QueueManagerDelegate)
- **Combine Bindings**: `@Published` properties bound using `.assign(to: &$property)`
- **Public API**: AudioPlayerService maintains same interface for UI compatibility

### 3. **Async Operations**
- **Background Loading**: LibraryService builds search index asynchronously
- **Queue Persistence**: Queue loading happens async to prevent main thread blocking
- **UI Responsiveness**: Heavy operations wrapped in `Task` blocks

## Development Guidelines

### Adding New Features
1. **Identify Service Responsibility**: Which service should handle the new functionality?
2. **Use Delegation**: Add delegate methods for cross-service communication
3. **Maintain Public API**: Keep AudioPlayerService interface stable for UI
4. **Async When Needed**: Wrap expensive operations in async contexts

### UI Best Practices  
- **Lazy Loading**: Use `LazyVStack`/`LazyHStack` for large lists
- **Stable IDs**: Use trackID-based IDs for SwiftUI view identity
- **Background Tasks**: Load data asynchronously, update UI on MainActor
- **Performance**: Avoid recreating views unnecessarily (stable IDs help)

### Performance Patterns
- **Caching**: Implement smart caching (see QueueSongCache, PlaybackQueue cache)
- **Lazy Evaluation**: Only load what's needed when it's needed
- **Debouncing**: Avoid rapid-fire updates (queueVersion increments)
- **Memory Management**: Clear caches when appropriate

## Current Status: Production Ready ✅

The app now has:
- ✅ **Stable Architecture**: Clean separation of concerns
- ✅ **Optimized Performance**: Hybrid search, lazy loading, async operations  
- ✅ **Responsive UI**: No main thread blocking, smooth animations
- ✅ **Feature Complete**: All original functionality preserved
- ✅ **Maintainable**: Clear patterns for future development

---

*Updated after Phase 3 completion - architecture refactoring successful*