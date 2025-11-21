# iPhone Music App - Project Context

## Project Overview
SwiftUI-based music player app for iPhone with clean service-oriented architecture. The app provides music library browsing, queue management, and audio playback with optimized search and responsive UI.

## Project Location & Build Instructions

### Project Structure
- **Project Path**: `/Users/zen/dev/src/amp/amp/`
- **Xcode Project**: `/Users/zen/dev/src/amp/amp/amp.xcodeproj`
- **Source Files**: `/Users/zen/dev/src/amp/amp/amp/` (this directory)

### Build Commands
```bash
# Navigate to project directory
cd /Users/zen/dev/src/amp/amp

# List available schemes and targets
xcodebuild -list -project amp.xcodeproj

# Build for iOS Simulator (iPhone 16)
xcodebuild -scheme amp -destination 'platform=iOS Simulator,name=iPhone 16' build

# Clean and build
xcodebuild -scheme amp -destination 'platform=iOS Simulator,name=iPhone 16' clean build

# Run tests
xcodebuild -scheme amp -destination 'platform=iOS Simulator,name=iPhone 16' test
```

### Available Targets
- **amp**: Main app target
- **ampTests**: Unit tests
- **ampUITests**: UI tests

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
- **LibraryService.swift**: Provides music library access and metadata enrichment from audio files.
- **SearchIndexService.swift**: Implements optimized hybrid search indexing (dictionary + scan) for fast diacritics-insensitive search. Extracted from LibraryService for better separation of concerns. Includes disk-based caching with automatic invalidation on library changes.

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

### Race Condition Prevention Pattern
```swift
// ANTI-PATTERN: State captured inside async Task (can become stale)
Task {
    let state = captureCurrentState()  // ❌ State captured asynchronously
    await performOperation(state)
}

// CORRECT: State captured synchronously before async operation
let state = captureCurrentState()  // ✅ State captured immediately
Task {
    await performOperation(state)  // Only operation is async
}

// CORRECT: Fail-safe checks before mutation after async operations
await MainActor.run {
    // Re-check state before mutation
    guard currentState.isValid else { return }  // ✅ Catch state changes
    mutateState()
}
```

### Combine Binding Safety Pattern
```swift
// ANTI-PATTERN: Using bound property immediately (race condition)
func doAction() {
    service.updateProperty()  // Sets service.property
    useProperty(self.property)  // ❌ Binding may not have propagated yet
}

// CORRECT: Use source property directly when immediate access needed
func doAction() {
    service.updateProperty()  // Sets service.property
    useProperty(service.property)  // ✅ Direct access, no race
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

### ✅ Phase 5: Search Engine Refinement (Completed)
**Goal**: Implement test-driven development for comprehensive search improvements
- ✅ Created comprehensive TDD framework with 180+ test cases
- ✅ Enhanced string normalization for special characters and diacritics
- ✅ Implemented robust prefix matching ("def" → "Deftones", "my own" → "My Own Summer")
- ✅ Added multi-language support and edge case handling
- ✅ Established iterative improvement workflow with regression detection

### ✅ Phase 6: Search Stability & Crash Prevention (Completed)
**Goal**: Eliminate search crashes and ensure robust error handling
- ✅ Fixed critical search crashes when searching for single letters ("s") or common terms ("Spice Girls")
- ✅ Added comprehensive input validation and safety checks
- ✅ Implemented memory management limits to prevent out-of-memory crashes
- ✅ Added search timeouts and graceful error handling
- ✅ Enhanced string processing safety with bounds checking and Unicode protection

### ✅ Phase 7: Architectural Erosion Remediation (Completed - Nov 2025)
**Goal**: Address architectural erosion, eliminate race conditions, and improve code quality
- ✅ **Separation of Concerns**: Extracted SearchIndexService from LibraryService (~690 line reduction), isolated mock data with #if DEBUG, migrated colors to Asset Catalog
- ✅ **Concurrency & Stability**: Eliminated all `asyncAfter` race condition hacks, replaced time-based delays with deterministic transition state enum and `defer` blocks
- ✅ **Performance**: Optimized blurred artwork with NSCache (automatic memory management), replaced character iteration with optimized string replacement APIs
- ✅ **Security**: Hardened notification permissions with error throwing, added real-time authorization status checks, audited ID3 tag parsing with strict AVMetadataKey constants and input validation
- ✅ **Documentation**: Updated architecture docs to reflect SearchIndexService extraction and removal of time-based synchronization

## Search Engine Test-Driven Development Framework

### Search Testing Architecture

The search functionality now includes a comprehensive test-driven development framework that ensures reliable, maintainable search improvements:

#### **Test Coverage (180+ Test Cases)**
- **Core Functionality**: Basic search operations, empty queries, exact matches
- **Diacritics Support**: "café" → "cafe", "naïve" → "naive", full Unicode normalization
- **Case Sensitivity**: Comprehensive case-insensitive matching across all languages
- **Special Characters**: Apostrophes, quotes, brackets, symbols, punctuation handling
- **Edge Cases**: Very long titles, single characters, numbers, whitespace handling
- **Word Boundaries**: Prefix matching with false positive prevention
- **Performance**: Sub-100ms response time validation with large datasets
- **Multi-Language**: Japanese, Chinese, Korean, Arabic, Hebrew, Thai character support
- **Prefix Matching**: Band name scenarios ("def" → "Deftones", "my own" → "My Own Summer")

#### **Test Framework Components**
- **MockDataGenerator.swift**: 130+ realistic test songs with comprehensive edge cases
- **SearchFunctionalityTests.swift**: Automated test suite with baseline establishment
- **SearchTestRunner.swift**: TDD workflow management with iteration tracking
- **PrefixMatchingTests.swift**: Specialized tests for band/song prefix scenarios
- **ComprehensiveSearchTesting.swift**: Complete validation workflow

#### **String Normalization Enhancements**
```swift
extension String {
    var searchNormalized: String {
        return self
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")      // don't → dont
            .replacingOccurrences(of: "&", with: "and")   // Rock & Roll → rock and roll
            .replacingOccurrences(of: "★", with: "")      // ★ Starman ★ → starman
            // ... comprehensive character handling
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

### Test-Driven Development Workflow

#### **1. Iterative Improvement Process**
```swift
// Establish baseline
SearchTestRunner.shared.establishBaseline()

// Make improvements
// ... implement search enhancements ...

// Validate changes
SearchTestRunner.shared.runTestAfterChanges(
    description: "Enhanced prefix matching",
    changes: "Added support for band name prefixes"
)

// Repeat until 100% pass rate
```

#### **2. Comprehensive Validation**
```swift
// Test specific scenarios
PrefixMatchingTests.testSpecificExamples()

// Run complete test suite
ComprehensiveSearchTesting.runCompleteWorkflow()

// Quick validation
ComprehensiveSearchTesting.quickValidateYourExamples()
```

#### **3. Regression Prevention**
- **Baseline Comparison**: Every change compared against established baseline
- **Automated Detection**: Immediate identification of broken functionality
- **Guided Fixes**: System provides specific improvement recommendations
- **Progress Tracking**: Complete history of all iterations and improvements

### Search Functionality Improvements

#### **Enhanced Prefix Matching**
- **Band Names**: "def" finds "Deftones", "The Deftones", "Def Leppard"
- **Multi-word**: "my own" finds "My Own Summer", "My Own Prison"
- **Article Handling**: "the deftones" correctly processed
- **False Positive Prevention**: "def" does NOT match "undefined" (substring)

#### **Special Character Handling**
- **Apostrophes**: "don't" → "dont", "can't" → "cant"
- **Quotes**: '"Heroes"' → "heroes", smart quotes normalized
- **Brackets**: "Song (Live)" → "song live"
- **Symbols**: "★ Starman ★" → "starman"
- **Ampersands**: "Rock & Roll" → "rock and roll"

#### **International Support**
- **Unicode Normalization**: Full diacritics support across languages
- **Multi-Script**: Japanese, Chinese, Korean, Arabic character handling
- **Consistent Processing**: Same normalization across all search paths

### Search Quality Metrics

#### **Performance Benchmarks**
- **Response Time**: < 100ms for queries across 25,000+ song libraries
- **Memory Efficiency**: Optimized indexing with smart caching
- **Scalability**: Tested with realistic music library sizes

#### **Accuracy Validation**
- **Precision**: Prefix matching with word boundary respect
- **Recall**: Comprehensive character normalization ensures matches found
- **Consistency**: Same behavior across songs, artists, albums

#### **User Experience**
- **Natural Queries**: "def" finds "Deftones" as expected
- **Forgiving Input**: Handles typos, case variations, punctuation
- **Fast Results**: Real-time search with immediate feedback

### Development Guidelines for Search

#### **Making Search Changes**
1. **Write Tests First**: Add test cases for new scenarios before implementation
2. **Run Baseline**: Establish current behavior before changes
3. **Implement Incrementally**: Small, focused improvements
4. **Validate Thoroughly**: Run complete test suite after each change
5. **Document Changes**: Record what was changed and why

#### **Search Architecture Patterns**
- **Consistent Normalization**: Use `searchNormalized` extension everywhere
- **Word Boundary Logic**: Implement prefix matching with false positive prevention
- **Performance First**: Index-based lookups with fallback scanning
- **Unicode Awareness**: Handle international characters properly
- **Safety First**: Always add input validation and result limits
- **Memory Management**: Implement result set limits and early termination
- **Error Handling**: Use timeout patterns and graceful degradation

#### **Testing Best Practices**
- **Comprehensive Coverage**: Test edge cases, not just happy paths
- **Real-world Data**: Use realistic band names, song titles, scenarios
- **Performance Validation**: Ensure changes don't degrade performance
- **Regression Prevention**: Always run full suite before considering complete
- **Crash Testing**: Test with problematic inputs like single letters and very long strings

#### **Search Safety Requirements**
- **Input Validation**: Maximum string lengths, character limits, word count limits
- **Memory Limits**: Result set size limits (1000 songs, 500 artists maximum)
- **Timeout Protection**: 10-second maximum search time with automatic cancellation
- **Thread Safety**: Proper async/await patterns with MainActor for UI updates
- **Unicode Safety**: String processing protection against malformed characters

## Current Status: Production Ready ✅

The app now has:
- ✅ **Clean Architecture**: Service-oriented design with clear separation of concerns
- ✅ **Optimized Performance**: Hybrid search, lazy loading, async operations
- ✅ **Responsive UI**: No main thread blocking, smooth animations
- ✅ **Feature Complete**: All original functionality preserved and enhanced
- ✅ **Maintainable**: Clear patterns and guidelines for future development
- ✅ **Stable Queue**: Ghost queue issue resolved with multi-layered fail-safe protections
- ✅ **Robust Search**: 180+ test cases with TDD framework for reliable search improvements
- ✅ **International Support**: Full Unicode normalization and multi-language search
- ✅ **User-Focused**: Natural prefix matching ("def" → "Deftones") with comprehensive validation
- ✅ **Crash-Resistant**: Search and queue stability with comprehensive safety checks
- ✅ **Memory Safe**: Result limits and timeout protection prevent resource exhaustion
- ✅ **Race Condition Safe**: Synchronous state capture and fail-safe checks prevent async corruption

## Recent Improvements

### Persisted Queue Playback Initialization Fix (Latest)
- **Problem**: When the app loaded a persisted queue from a previous session, pressing the play button would do nothing. The queue and current track were restored, but no audio would play.
- **Root Cause**: The `QueueManagerService.loadQueue()` method would set `currentTrack` when restoring a persisted queue, but never notified the `AudioPlayerService` delegate. This meant the `PlaybackEngineService` was never initialized with the track, so it had no audio loaded when the user pressed play.
- **Solution**: Added delegate notification when restoring the current track from persisted queue:
  - `QueueManagerService.swift:467`: Added `delegate?.currentTrackDidChange(songs[index])` call when restoring current track
  - `AudioPlayerService.currentTrackDidChange()`: Already had proper logic to call `playbackEngine.loadWithoutPlaying()` when not playing
  - `PlaybackEngineService.playPause()`: Added warning message when called with no audio loaded
- **Impact**: Persisted queues now properly initialize the audio player on app launch. Users can immediately press play and resume playback from their previous session.
- **Files**:
  - `QueueManagerService.swift:462-469` (delegate notification on queue restore)
  - `AudioPlayerService.swift:91-105` (diagnostic logging added)
  - `PlaybackEngineService.swift:103-157` (warning for no-audio-loaded case)

### Previous: Queue Stability & Ghost Queue Fix
- **Problem**: Queue would become corrupted during playback, showing wrong album art and tracks from previous sessions. Specifically, album art would change to songs from the same position in a previously-loaded queue, and going back to "previous" would play the ghost track instead of the actual track.
- **Root Cause**: Multiple interconnected race conditions:
  1. **State Capture Race in `saveQueue()`**: Queue state was captured inside async `Task` block, allowing state to change between capture and persistence
  2. **Combine Binding Race in `startPlayback()`**: Used bound `currentTrack` property instead of direct source, causing stale track references
  3. **Double Playback Calls**: Both manual playback and delegate callback would trigger `playbackEngine.play()`, creating conflicts
  4. **Async Load Race**: `loadQueue()` would pass initial protections but state would change during the ~1 second disk load, then overwrite active queue when mutation happened
- **Solution**: Multi-layered protection system:
  1. Synchronous state capture in `saveQueue()` before async persistence (`QueueManagerService.swift:287-308`)
  2. Direct track reference in `startPlayback()` to avoid Combine binding delay (`AudioPlayerService.swift:90-106`)
  3. `isManuallyStarting` flag to prevent delegate double-play (`AudioPlayerService.swift:15-16, 258-278`)
  4. Fail-safe checks in `loadQueue()` MainActor block to catch state changes during async load (`QueueManagerService.swift:432-447`)
  5. Comprehensive entry logging to track all `loadQueue()` calls (`QueueManagerService.swift:342-343`)
- **Impact**: Queue is now completely stable. No more ghost tracks, correct album art throughout playback, proper previous/next track behavior, and reliable queue persistence.
- **Files**:
  - `QueueManagerService.swift:15-28, 287-308, 341-474` (state capture, logging, fail-safes)
  - `AudioPlayerService.swift:15-16, 90-121, 258-278` (manual start protection)

### Previous: Notification Bug Fix
- **Problem**: Track change notifications weren't showing at all
- **Root Cause**: Inverted logic in `PlaybackEngineService.swift` where `shouldSkip` was incorrectly passed as `isManualSelection`, causing all automatic track changes to be treated as manual selections and thus skipped
- **Solution**: Fixed notification parameter passing and added comprehensive debug logging
- **Impact**: Notifications now properly show when tracks change automatically (when app is backgrounded or user is not on Now Playing view)
- **Files**: `PlaybackEngineService.swift:843-853`, `NotificationService.swift:137-171`

### Previous: Pause/Resume Bug Fix
- **Problem**: Paused songs restarted from the beginning instead of resuming from the paused position
- **Root Cause**: `AudioPlayerService.playPause()` incorrectly called `playbackEngine.play()` when no audio was ready, bypassing the proper resume logic
- **Solution**: Simplified `playPause()` to always delegate to `playbackEngine.playPause()`, which contains comprehensive pause/resume handling
- **Impact**: Songs now properly resume from their paused position, maintaining user's playback context
- **Files**: `AudioPlayerService.swift:100-108`

### Previous: Search Crash Prevention
- **Problem**: App crashed when searching for single letters ("s") or common terms ("Spice Girls")
- **Root Cause**: Memory explosion from uncontrolled result sets, missing input validation, and unsafe string processing
- **Solution**: Comprehensive safety system with input validation, result limits, timeouts, and error handling
- **Impact**: Search is now stable and responsive for all queries, including previously problematic ones

### Key Safety Features Added
- **Input Validation**: 100-character search limit, 10-word maximum, empty string protection
- **Memory Management**: 1000 song/500 artist result limits with early termination
- **Timeout Protection**: 10-second search timeout with automatic cancellation
- **String Safety**: Unicode processing protection and bounds checking
- **Error Handling**: Graceful degradation with proper async/await patterns
- **Queue Protection**: Multi-layered fail-safes prevent ghost queue loading during active playback

---

*Updated after persisted queue playback initialization fix - play button now works with restored queues*