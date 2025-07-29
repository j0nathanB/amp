import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Tab = .queue // Default tab is now Queue
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    @State private var isKeyboardVisible = false
    
    // Create persistent instances of each view
//    @StateObject private var queueViewModel = QueueViewModel()
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // A switch statement now controls which main view is visible
                ZStack {
                    // Always keep these views in memory for state persistence
                    PlaylistsView()
                        .opacity(selectedTab == .playlists ? 1 : 0)
                        .disabled(selectedTab != .playlists)
                    
                    QueueView()
                        .opacity(selectedTab == .queue ? 1 : 0)
                        .disabled(selectedTab != .queue)
                    
                    // SearchView is conditionally rendered to avoid keyboard issues
                    if selectedTab == .search {
                        SearchView()
                    } else {
                        Color.clear
                    }
                    
                    NowPlayingView()
                        .opacity(selectedTab == .nowPlaying ? 1 : 0)
                        .disabled(selectedTab != .nowPlaying)
                }


                // Only show the custom tab bar if the keyboard is not visible
                if !isKeyboardVisible {
                    CustomTabView(selectedTab: $selectedTab)
                        .transition(.move(edge: .bottom))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .ignoresSafeArea(.keyboard)
        .animation(.linear(duration: 0.1), value: isKeyboardVisible)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    self.isKeyboardVisible = true
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    self.isKeyboardVisible = false
                }
                .onReceive(audioPlayer.$selectedTab) { newTab in
                    withAnimation(.linear(duration: 0.1)) {
                        selectedTab = newTab
                    }
                    selectedTab = newTab
                }
    }
}
