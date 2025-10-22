import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Tab = .queue // Default tab is now Queue
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    @State private var isKeyboardVisible = false
    
    
    var body: some View {
        ZStack {
            // Full screen content area
            Group {
                switch selectedTab {
                case .playlists:
                    PlaylistsView()
                        .padding(.top, 8)
                        .padding(.bottom, 80)
                        .padding(.horizontal, 16)
                case .queue:
                    QueueView()
                        .padding(.top, 8)
                        .padding(.bottom, 80)
                        .padding(.horizontal, 16)
                case .search:
                    SearchView()
                        .padding(.top, 8)
                        .padding(.bottom, 80)
                        .padding(.horizontal, 16)
                case .nowPlaying:
                    NowPlayingView()
                        .padding(16)
                        .padding(.bottom, 60)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Fixed tab bar overlay at bottom - always visible
            VStack {
                Spacer()
                CustomTabView(selectedTab: $selectedTab)
                    .opacity(isKeyboardVisible ? 0 : 1)
                    .animation(.linear(duration: 0.1), value: isKeyboardVisible)
            }
        }
        .background(Color.clear)
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
        }
    }
}
