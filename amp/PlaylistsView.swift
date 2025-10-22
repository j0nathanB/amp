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
                    .padding(.vertical, 20)
                    .padding(.horizontal, 16)
                    .background(Theme.background)

                // Separator line below header
                Rectangle()
                    .fill(Theme.primaryText)
                    .frame(height: 2)

                ScrollView {
                    LazyVStack(spacing: -1) {
                        ForEach(playlists) { playlist in
                            PlaylistItemView(playlist: playlist) {
                                play(playlist: playlist)
                            }
                        }
                    }
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
        ListItemView(
            title: playlist.name,
            subtitle: "",
            detail: nil,
            isPressed: isPressed,
            textAlignment: .center
        )
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
