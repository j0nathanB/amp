import SwiftUI

// Spec §6: four tabs (LIBRARY / SEARCH / QUEUE / ACTIVE), each owning its own
// NavigationStack. Tab bar lives at the bottom on a cream strip; content fills
// the space above it. Pushed views (Album/Artist/Playlist Detail, Settings,
// Lyrics) live inside the owning tab's stack.
//
// Phase C wires this up against the *existing* tab root views (PlaylistsView,
// SearchView, QueueView, NowPlayingView). Their internals get redesigned in
// Phase D/E.

struct MainTabView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var nav = NavigationService.shared

    @State private var isKeyboardVisible = false
    @State private var didPickInitialTab = false

    var body: some View {
        VStack(spacing: 0) {
            // Spec §2.1: white content frame with 2px black stroke sits on
            // the cream canvas. 8pt cream strip shows on all four sides of
            // the frame; the tab bar then sits on its own cream row below.
            //
            // .strokeBorder (not .stroke) keeps the full 2px on the inside
            // of the rectangle — a centered stroke would put 1px outside
            // and the bottom half would get clipped by the adjacent tab bar.
            contentArea
                .overlay(Rectangle().strokeBorder(Color.ampBlack, lineWidth: 2))
                .padding(8)
            if !isKeyboardVisible {
                tabBar
                    .transition(.opacity)
            }
        }
        .animation(.linear(duration: 0.1), value: isKeyboardVisible)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onAppear {
            // Eager track restore in AudioPlayerService.init runs synchronously
            // before the first frame, so currentTrack is already populated here
            // if there's a persisted track. Decide the launch tab once based on
            // that signal, then leave selectedTab alone.
            guard !didPickInitialTab else { return }
            didPickInitialTab = true
            if audioPlayer.currentTrack != nil {
                nav.selectedTab = .active
            }
        }
    }

    // Each tab owns a NavigationStack bound to its path in NavigationService.
    // ZStack + opacity keeps all four tabs alive so per-tab UI state (scroll
    // position, in-flight async work, etc.) survives tab switches — matching
    // the spec's "tap a tab while on a pushed view → pop to root" contract,
    // which relies on the path binding being live across tab changes.
    private var contentArea: some View {
        ZStack {
            ForEach(AmpTab.allCases, id: \.self) { tab in
                NavigationStack(path: nav.pathBinding(for: tab)) {
                    tabRoot(tab)
                        .navigationDestination(for: AmpRoute.self) { route in
                            AmpRouteDestination(route: route)
                        }
                }
                .opacity(nav.selectedTab == tab ? 1 : 0)
                .allowsHitTesting(nav.selectedTab == tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tabRoot(_ tab: AmpTab) -> some View {
        switch tab {
        case .library: LibraryView()
        case .search: SearchView()
        case .queue: QueueView()
        case .active: NowPlayingView()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(AmpTab.allCases, id: \.self) { tab in
                TabBarTab(tab: tab, isSelected: nav.selectedTab == tab) {
                    nav.handleTabTap(tab)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color.ampCream)
    }
}
