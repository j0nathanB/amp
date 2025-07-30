import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Tab = .queue // Default tab is now Queue
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    @State private var isKeyboardVisible = false
    
    
    var body: some View {
        VStack(spacing: 0) {
            // Clean switch-based approach
            Group {
                switch selectedTab {
                case .playlists:
                    PlaylistsView()
                case .queue:
                    QueueView()
                case .search:
                    SearchView()
                case .nowPlaying:
                    NowPlayingView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            
            // Only show the custom tab bar if the keyboard is not visible
            if !isKeyboardVisible {
                CustomTabView(selectedTab: $selectedTab)
                    .transition(.move(edge: .bottom))
            }
        }
        .background(Color.clear)
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
