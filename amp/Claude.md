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

The app follows a clean service-oriented architecture with clear separation of concerns:

### Core Services
- **AudioPlayerService.swift**: Main orchestrator that coordinates all services while maintaining a stable public API for UI components. Acts as the single point of contact for all audio operations.
- **PlaybackEngineService.swift**: Handles pure audio operations using AVAudioPlayer - play/pause/seek, audio session management, now playing info, and audio completion events.
- **QueueManagerService.swift**: Manages playback queue state, track navigation (next/previous), queue persistence, and shuffle functionality.
- **NavigationService.swift**: Controls UI navigation state and tab selection.
- **LibraryService.swift**: Provides optimized music library search with hybrid dictionary + scan indexing for fast diacritics-insensitive search.

### UI Components
- **NowPlayingView.swift**: Current track display and playback controls
- **QueueView.swift**: Queue management with lazy loading and scroll optimization
- **PlaylistsView.swift**: Library browsing and playlist selection
- **SearchView.swift**: Search interface with real-time filtering
- **MainTabView.swift**: Main navigation container
- **CustomTabView.swift**: Custom tab bar implementation

### Data Layer
- **PlaybackQueue.swift**: Queue management with caching, shuffle support, and state persistence
- **DataModels.swift**: Core data structures (Song, Artist, Album, Tab)
- **Theme.swift**: UI theming and styling constants

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

## Architectural Decisions Made

### Service Communication
**Decision**: Use delegation pattern for cross-service communication instead of direct service-to-service calls.
**Rationale**: Maintains loose coupling, clear responsibilities, and prevents circular dependencies.

### State Management
**Decision**: Use Combine's `@Published` properties with `.assign(to:)` bindings for reactive state updates.
**Rationale**: Provides automatic UI updates while keeping services decoupled from UI layer.

### Audio Session Management
**Decision**: Centralize all AVAudioPlayer operations in PlaybackEngineService.
**Rationale**: Ensures single source of truth for audio state, prevents conflicts, and simplifies debugging.

### Queue Persistence
**Decision**: Store only track IDs, not full Song objects, in UserDefaults.
**Rationale**: Reduces storage overhead and handles library changes gracefully (missing tracks are filtered out).

### Error Handling
**Decision**: Use completion-based patterns for track transitions rather than throwing errors.
**Rationale**: Audio playback should be resilient - if one track fails, continue to next track.

## Established Patterns & Conventions

### Service Creation Pattern
```swift
class ServiceName: ObservableObject {
    weak var delegate: ServiceDelegate?
    @Published private(set) var property = initialValue
    
    init() {
        // Async initialization when needed
        Task { await setupService() }
    }
}
```

### Delegation Pattern
```swift
protocol ServiceDelegate: AnyObject {
    func serviceDidChange()
    func serviceDidComplete(_ result: Type)
}
```

### Combine Binding Pattern
```swift
private func setupBindings() {
    serviceA.$property.assign(to: &$publicProperty)
    serviceB.$anotherProperty
        .map { /* transform */ }
        .assign(to: &$transformedProperty)
}
```

### Async UI Update Pattern
```swift
Task {
    let result = await heavyOperation()
    await MainActor.run {
        self.property = result
    }
}
```

## Development Workflow

### Adding New Features
1. **Identify Service**: Determine which service should handle the functionality
2. **Define Delegate Methods**: Add any needed cross-service communication
3. **Update Public API**: Extend AudioPlayerService interface if needed
4. **Implement & Test**: Add functionality while maintaining existing patterns
5. **Update Bindings**: Ensure new `@Published` properties are properly bound

### Bug Fixes
1. **Identify Layer**: Determine if issue is in Service, UI, or Data layer
2. **Check Delegates**: Verify delegate methods are called correctly
3. **Review State Flow**: Ensure `@Published` properties update as expected
4. **Test Edge Cases**: Verify fix works with queue empty, shuffled, etc.

### Performance Optimization
1. **Profile First**: Use Instruments to identify actual bottlenecks
2. **Async When Possible**: Move heavy operations off main thread
3. **Cache Smartly**: Implement caching where data is expensive to recreate
4. **Lazy Load**: Only load UI elements when needed

## Feature Roadmap

### Near Term (Next Sprints)
- **Playback Controls**: Volume control, playback speed adjustment
- **Queue Management**: Reorder tracks, remove from queue
- **Library Features**: Recently played, most played tracking

### Medium Term
- **Playlist Management**: Create, edit, delete custom playlists
- **Audio Effects**: Equalizer, crossfade between tracks
- **Offline Mode**: Cache frequently played tracks locally

### Long Term
- **Social Features**: Share playlists, collaborative queues
- **Cloud Sync**: Sync preferences across devices
- **Advanced Search**: Smart playlists, advanced filtering

## Refactoring History

### ✅ Phase 1: Stabilize 🛠️ (Completed)
**Goal**: Fix compiler errors and get app running reliably
- ✅ Unified dual-queue system into single PlaybackQueue model
- ✅ Refactored AudioPlayerService to use unified queue
- ✅ Fixed dependent views (NowPlayingView, QueueView)

### ✅ Phase 2: Optimize ⚡ (Completed)
**Goal**: Fix performance bottleneck in library search  
- ✅ Implemented diacritics-insensitive search with string normalization
- ✅ Built hybrid dictionary + scan search indexing
- ✅ Fixed artist search by building index from songs rather than MPMediaQuery.artists()

### ✅ Phase 3: Decompose 🏛️ (Completed)
**Goal**: Break apart the monolithic service for better architecture
- ✅ Extracted PlaybackEngineService (AVAudioPlayer, audio session, now playing info)
- ✅ Extracted QueueManagerService (PlaybackQueue management, persistence) 
- ✅ Extracted NavigationService (UI navigation state)
- ✅ Created orchestrating AudioPlayerService with same public API
- ✅ Fixed async initialization to prevent main thread blocking

### ✅ Phase 4: Iterate (Completed)
**Goal**: Establish patterns for ongoing development
- ✅ Documented service architecture patterns
- ✅ Created development guidelines for future features
- ✅ Fixed auto-play bug in track transitions
- ✅ Established conventions for service communication and state management

## Current Status: Production Ready ✅

The app now has:
- ✅ **Clean Architecture**: Service-oriented design with clear separation of concerns
- ✅ **Optimized Performance**: Hybrid search, lazy loading, async operations  
- ✅ **Responsive UI**: No main thread blocking, smooth animations
- ✅ **Feature Complete**: All original functionality preserved and enhanced
- ✅ **Maintainable**: Clear patterns and guidelines for future development
- ✅ **Bug-Free**: Track auto-play and other issues resolved

---

*Updated after 4-phase refactoring completion - ready for ongoing feature development*