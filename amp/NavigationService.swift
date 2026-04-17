import Foundation
import SwiftUI
import MediaPlayer

// Spec §6 + §8.2: each tab owns its own navigation stack; cross-tab switching
// preserves per-tab path state. Tap-same-tab-on-root scrolls to top,
// tap-same-tab-on-pushed-view pops all the way back.
//
// Singleton so external triggers (notifications, deep links) can navigate
// without needing a SwiftUI environment handle.

final class NavigationService: ObservableObject {
    static let shared = NavigationService()
    private init() {}

    @Published var selectedTab: AmpTab = .queue

    @Published var libraryPath = NavigationPath()
    @Published var searchPath = NavigationPath()
    @Published var queuePath = NavigationPath()
    @Published var activePath = NavigationPath()

    // Binding handed to each per-tab NavigationStack in MainTabView.
    func pathBinding(for tab: AmpTab) -> Binding<NavigationPath> {
        switch tab {
        case .library:
            Binding(get: { self.libraryPath }, set: { self.libraryPath = $0 })
        case .search:
            Binding(get: { self.searchPath }, set: { self.searchPath = $0 })
        case .queue:
            Binding(get: { self.queuePath }, set: { self.queuePath = $0 })
        case .active:
            Binding(get: { self.activePath }, set: { self.activePath = $0 })
        }
    }

    // Push a route onto whichever tab is currently selected. Views that
    // live inside a pushed stack (e.g. ArtistDetail pushing AlbumDetail)
    // don't know which tab they're in; `push` picks the right path
    // without each caller having to branch on selectedTab.
    func push(_ route: AmpRoute) {
        switch selectedTab {
        case .library: libraryPath.append(route)
        case .search: searchPath.append(route)
        case .queue: queuePath.append(route)
        case .active: activePath.append(route)
        }
    }

    func popToRoot(_ tab: AmpTab) {
        switch tab {
        case .library: libraryPath = NavigationPath()
        case .search: searchPath = NavigationPath()
        case .queue: queuePath = NavigationPath()
        case .active: activePath = NavigationPath()
        }
    }

    func isAtRoot(_ tab: AmpTab) -> Bool {
        switch tab {
        case .library: libraryPath.isEmpty
        case .search: searchPath.isEmpty
        case .queue: queuePath.isEmpty
        case .active: activePath.isEmpty
        }
    }

    // Tab-bar tap handler: different tab → switch; same tab on pushed view →
    // pop to root; same tab at root → signal scroll-to-top (listened for by root views).
    func handleTabTap(_ tab: AmpTab) {
        if selectedTab == tab {
            if isAtRoot(tab) {
                NotificationCenter.default.post(name: .ampScrollToTop, object: tab)
            } else {
                popToRoot(tab)
            }
        } else {
            selectedTab = tab
        }
    }

    // External triggers (notification tap, etc.) jump to the Active tab root.
    func showNowPlaying() {
        selectedTab = .active
        popToRoot(.active)
    }

    // Legacy convenience methods retained for existing callers.
    func navigateToNowPlaying() {
        selectedTab = .active
    }

    func navigateToQueue() {
        selectedTab = .queue
    }

    func navigateToSearch() {
        selectedTab = .search
    }

    func navigateToLibrary() {
        selectedTab = .library
    }
}

extension Notification.Name {
    static let ampScrollToTop = Notification.Name("ampScrollToTop")
}

// MARK: - Track-scoped navigation helpers
//
// Info-strip taps (artist name, "From {Album}", genre) need to resolve a
// track's albumArtistPersistentID / albumPersistentID before pushing.
// Centralizing here keeps the MPMediaQuery boilerplate out of views.

extension NavigationService {
    func navigateToArtist(forTrack trackID: MPMediaEntityPersistentID) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: trackID),
                forProperty: MPMediaItemPropertyPersistentID
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            guard let item = query.items?.first else { return }
            let id = item.albumArtistPersistentID != 0
                ? item.albumArtistPersistentID
                : item.artistPersistentID
            guard id != 0 else { return }
            await MainActor.run {
                self?.push(.artistDetail(id))
            }
        }
    }

    func navigateToAlbum(forTrack trackID: MPMediaEntityPersistentID) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: trackID),
                forProperty: MPMediaItemPropertyPersistentID
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            guard let item = query.items?.first else { return }
            let id = item.albumPersistentID
            guard id != 0 else { return }
            await MainActor.run {
                self?.push(.albumDetail(id))
            }
        }
    }

    func navigateToGenre(_ genre: String) {
        let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "—" else { return }
        push(.genreDetail(trimmed))
    }
}
