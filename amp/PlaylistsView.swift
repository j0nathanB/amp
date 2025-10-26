import SwiftUI

struct PlaylistsView: View {
    @State private var playlists: [Playlist] = []
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom header with controlled spacing
                Text("Playlists")
                    .font(Theme.titleFont)
                    .foregroundColor(Theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 28)
                    .padding(.vertical, 20)
                    .padding(.horizontal, 16)
                    .background(Theme.background)

                // Separator line below header
                Rectangle()
                    .fill(Theme.primaryText)
                    .frame(height: 2)

                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(playlists) { playlist in
                            PlaylistItemView(playlist: playlist) {
                                play(playlist: playlist)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                Spacer()

                // Bottom bars section
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
            }
            .navigationBarHidden(true)
            .onAppear {
                var userPlaylists = LibraryService.shared.getPlaylists()
                let allSongsPlaylist = Playlist(id: 0, name: "All Songs")
                userPlaylists.insert(allSongsPlaylist, at: 0)
                self.playlists = userPlaylists
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
                .fill(Theme.accentDarkGreen)
                .offset(x: -6, y: 6)

            // Main content
            ListItemView(
                title: playlist.name,
                subtitle: "",
                detail: nil,
                isPressed: isPressed,
                textAlignment: .center
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
