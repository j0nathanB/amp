import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Tab = .queue // Default tab is now Queue
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @StateObject private var settings = SettingsService.shared

    @State private var isKeyboardVisible = false


    var body: some View {
        ZStack {
            // Dominant color gradient background (when enabled and on Now Playing tab)
            if settings.albumBackground, selectedTab == .nowPlaying, let currentTrack = audioPlayer.currentTrack {
                DominantColorBackground(song: currentTrack)

                // Vignette overlay for depth and text legibility
                GeometryReader { geometry in
                    Rectangle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color.black.opacity(0),
                                    Color.black.opacity(0.3)
                                ]),
                                center: .center,
                                startRadius: geometry.size.width * 0.3,
                                endRadius: geometry.size.width * 0.8
                            )
                        )
                        .ignoresSafeArea()
                }

                // Subtle white overlay for brightness
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .ignoresSafeArea()
            } else {
                // Default background (white in light mode, black in dark mode)
                Theme.background
                    .ignoresSafeArea()
            }

            // Full screen content area
            Group {
                switch selectedTab {
                case .playlists:
                    PlaylistsView()
                        .padding(.top, 8)
                        .padding(.bottom, 85)
                        .padding(.horizontal, 16)
                case .queue:
                    QueueView()
                        .padding(.top, 8)
                        .padding(.bottom, 85)
                        .padding(.horizontal, 16)
                case .search:
                    SearchView()
                        .padding(.top, 8)
                        .padding(.bottom, 85)
                        .padding(.horizontal, 16)
                case .nowPlaying:
                    NowPlayingView()
                        .padding(.top, 8)
                        .padding(.bottom, 85)
                        .padding(.horizontal, 16)
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
