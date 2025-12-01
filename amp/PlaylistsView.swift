import SwiftUI

struct PlaylistsView: View {
    @State private var playlists: [Playlist] = []
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var isScrollable = false
    @State private var isAtBottom = false
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom header with controlled spacing
                HStack {
                    Text("Playlists")
                        .font(Theme.titleFont)
                        .foregroundColor(Theme.primaryText)

                    Spacer()

                    Button(action: {
                        showSettings = true
                    }) {
                        Text("Settings")
                            .font(Theme.bodyFont)
                            .foregroundColor(showSettings ? Color.white : Theme.primaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        ZStack {
                            // Shadow layer
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.accentDarkIndigo)
                                .offset(x: -6, y: 6)

                            // Main container
                            RoundedRectangle(cornerRadius: 6)
                                .fill(showSettings ? Theme.accentLightBlue : Color.white)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.primaryText, lineWidth: 2)
                    )
                }
                .frame(height: 28)
                .padding(.vertical, 20)
                .padding(.horizontal, 16)
                .background(Theme.background)

                // Separator line below header
                Rectangle()
                    .fill(Theme.primaryText)
                    .frame(height: 2)

                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            LazyVStack(spacing: 20) {
                                ForEach(playlists) { playlist in
                                    PlaylistItemView(playlist: playlist) {
                                        play(playlist: playlist)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            // Invisible anchor at the bottom to track scroll position
                            Color.clear
                                .frame(height: 1)
                                .background(
                                    GeometryReader { bottomGeometry in
                                        Color.clear.preference(
                                            key: ScrollOffsetPreferenceKey.self,
                                            value: bottomGeometry.frame(in: .named("playlists-scroll")).minY
                                        )
                                    }
                                )
                        }
                        .background(
                            GeometryReader { contentGeometry in
                                Color.clear.preference(
                                    key: ContentHeightPreferenceKey.self,
                                    value: contentGeometry.size.height
                                )
                            }
                        )
                    }
                    .coordinateSpace(name: "playlists-scroll")
                    .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
                        contentHeight = height
                        viewportHeight = geometry.size.height
                        isScrollable = height > geometry.size.height
                    }
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { bottomOffset in
                        // bottomOffset is the Y position of the bottom anchor in the scroll view
                        // When at top: bottomOffset ≈ contentHeight
                        // When at bottom: bottomOffset ≈ viewportHeight
                        let threshold: CGFloat = 20

                        if isScrollable {
                            // We're at the bottom when the bottom anchor is visible near the bottom of viewport
                            isAtBottom = bottomOffset <= (viewportHeight + threshold)
                        } else {
                            // Content fits entirely in viewport
                            isAtBottom = true
                        }
                    }
                }

                Spacer()

                // Bottom bars section - only show when content is scrollable AND not at bottom
                if isScrollable && !isAtBottom {
                    VStack(spacing: 0) {
                        // Light blue gradient bar (16px)
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [.white.opacity(0), Theme.accentSkyBlue]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 16)

                        // 2px separator bar with 10px bottom padding
                        Rectangle()
                            .fill(Theme.primaryText)
                            .frame(height: 2)
                            .padding(.bottom, 10)
                    }
                    .transition(.opacity)
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                var userPlaylists = LibraryService.shared.getPlaylists()
                let allSongsPlaylist = Playlist(id: 0, name: "All Songs")
                userPlaylists.insert(allSongsPlaylist, at: 0)
                self.playlists = userPlaylists
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }
    
    // This is the corrected playback function
    private func play(playlist: Playlist) {
        Task {
            let songs: [Song]
            
            if playlist.id == 0 {
                // Get all songs directly from the library service
                songs = LibraryService.shared.getAllSongs()
            } else {
                songs = LibraryService.shared.getSongs(forPlaylist: playlist.id)
            }
            
            // Now, start playback with the full list of songs
            if let firstSong = songs.first {
                await MainActor.run {
                    audioPlayer.startPlayback(from: songs, startingWith: firstSong)
                }
            }
        }
    }
}

// Playlist item with press state
private struct PlaylistItemView: View {
    let playlist: Playlist
    let action: () -> Void
    @GestureState private var isPressed = false

    var body: some View {
        ZStack {
            // Offset shadow layer
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.accentDarkIndigo)
                .offset(x: -6, y: 6)

            // Main content
            ListItemView(
                title: playlist.name,
                subtitle: "",
                detail: nil,
                isPressed: isPressed,
                textAlignment: .center,
                backgroundColor: Theme.accentGreen
            )
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.primaryText, lineWidth: 2)
            )
        }
        .onTapGesture {
            action()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in
                    state = true
                }
        )
    }
}
