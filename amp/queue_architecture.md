Queue Management Architecture

    The queue in this music app is managed through a layered architecture
    with clear separation of concerns:

    Core Components:

    1. PlaybackQueue (Data Model) - amp/PlaybackQueue.swift:4-177
      - Struct that holds queue state (track IDs, current index, shuffle
    state)
      - Manages track order and navigation (next/previous)
      - Implements caching for recently accessed songs (50 song limit)
      - Supports shuffle/unshuffle with original order preservation
      - Persists only track IDs for memory efficiency
    2. QueueManagerService (State Management) -
    amp/QueueManagerService.swift:9-168
      - ObservableObject that manages the PlaybackQueue
      - Publishes queue changes via @Published properties
      - Handles queue persistence to UserDefaults
      - Manages shuffle state and preferences
      - Delegates track changes to AudioPlayerService
    3. AudioPlayerService (Orchestration) -
    amp/AudioPlayerService.swift:4-195
      - Main orchestrator that coordinates all services
      - Provides unified public API for UI components
      - Binds service properties using Combine
      - Manages playback state transitions

    Queue Operations Flow:

    1. Adding Songs to Queue:
      - UI calls audioPlayer.startPlayback(from: songs, startingWith: song)
      - QueueManagerService sets tracks in PlaybackQueue
      - Applies shuffle if enabled
      - Saves queue to UserDefaults
      - Triggers navigation to NowPlayingView
    2. Track Navigation:
      - Next/Previous operations update currentIndex in PlaybackQueue
      - QueueManagerService notifies delegates of changes
      - AudioPlayerService loads and plays the new track
      - Queue persistence is updated automatically
    3. Queue Display:
      - QueueView uses LazyVStack for performance
      - LazyQueueItemView loads songs on-demand
      - QueueSongCache prevents redundant loading
      - Auto-scrolls to current track when appropriate

    Key Design Decisions:

    - ID-based Storage: Only MPMediaEntityPersistentIDs are stored, not
    full Song objects
    - Lazy Loading: Songs loaded from library only when needed for display
    - Caching Strategy: Two-tier cache (PlaybackQueue + QueueSongCache) for
     optimal performance
    - State Management: Combine @Published properties for reactive UI
    updates
    - Shuffle Implementation: Preserves original order for unshuffle
    capability


⏺ The queue is managed through a clean three-layer architecture:

  PlaybackQueue (amp/PlaybackQueue.swift:4-177) - The data model struct
  that:
  - Stores track IDs and current index
  - Implements navigation (next/previous) logic
  - Manages shuffle state with original order preservation
  - Provides lazy-loading with 50-song cache

  QueueManagerService (amp/QueueManagerService.swift:9-168) - The state
  manager that:
  - Wraps PlaybackQueue as @Published property
  - Handles persistence to UserDefaults
  - Manages shuffle preferences
  - Notifies delegates of queue changes

  AudioPlayerService (amp/AudioPlayerService.swift:4-195) - The orchestrator
   that:
  - Coordinates between QueueManager and PlaybackEngine
  - Provides unified API for UI components
  - Binds service states using Combine
  - Manages playback transitions

  The queue flow works by storing only track IDs for efficiency,
  lazy-loading songs when needed for display, and using a two-tier caching
  strategy (PlaybackQueue cache + QueueSongCache) to optimize performance
  while preventing memory buildup.