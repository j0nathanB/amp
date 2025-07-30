import SwiftUI

struct PlaylistsView: View {
    @State private var playlists: [Playlist] = []
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: -1) {
                    ForEach(playlists) { playlist in
                        Button(action: {
                            play(playlist: playlist)
                        }) {
                            ListItemView(
                                title: playlist.name,
                                subtitle: "",
                                detail: nil
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("Playlists").font(Theme.titleFont).foregroundColor(Theme.primaryText)
                }
            }
            .onAppear {
                var userPlaylists = LibraryService.shared.getPlaylists()
                let allSongsPlaylist = Playlist(id: 0, name: "All Songs")
                userPlaylists.insert(allSongsPlaylist, at: 0)
                self.playlists = userPlaylists
            }
        }
        .padding(16) // Match NowPlayingView padding
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
