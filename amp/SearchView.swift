import SwiftUI
import MediaPlayer

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The top spacer for padding
                Spacer().frame(height: 20)
                
                SearchBarView(searchText: $viewModel.searchText)
                    .onChange(of: viewModel.searchText) {
                        viewModel.performSearch()
                    }
                
                SearchResultsView(results: viewModel.searchResults)
                    .environmentObject(audioPlayer)
                
                // The spacer to push the tab bar to the bottom
                Spacer(minLength: 0)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("Search")
                        .font(Theme.titleFont)
                        .foregroundColor(Theme.primaryText)
                }
            }
        }
        .padding(16) // Match NowPlayingView padding
    }
}

struct SearchBarView: View {
    @Binding var searchText: String
    @FocusState private var isSearchFieldFocused: Bool
    
    var body: some View {
        HStack {
            TextField("Search Songs, Artists, Albums...", text: $searchText)
                .focused($isSearchFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    isSearchFieldFocused = false
                }

            if !searchText.isEmpty {
                Button(action: {
                    self.searchText = ""
                    self.isSearchFieldFocused = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(
            Rectangle()
                .fill(.white)
                .stroke(.black, lineWidth: 1)
        )
        .padding(.horizontal)
    }
}

struct SearchResultsView: View {
    let results: SearchResults
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        // Use a ScrollView for the stacked-card layout
        ScrollView {
            // Negative spacing creates the border overlap
            LazyVStack(spacing: -1) {
                if !results.artists.isEmpty {
                    Text("Artists").font(Theme.sectionHeaderFont).frame(maxWidth: .infinity, alignment: .leading).padding()
                    ForEach(results.artists) { artist in
                        Button(action: {
                            playArtist(artist)
                        }) {
                            ListItemView(title: artist.name, subtitle: nil, detail: nil)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                
                if !results.albums.isEmpty {
                    Text("Albums").font(Theme.sectionHeaderFont).frame(maxWidth: .infinity, alignment: .leading).padding()
                    ForEach(results.albums) { album in
                        Button(action: {
                            playAlbum(album)
                        }) {
                            ListItemView(title: album.title, subtitle: album.artist, detail: nil, italicizeTitle: true)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                
                if !results.songs.isEmpty {
                    Text("Songs").font(Theme.sectionHeaderFont).frame(maxWidth: .infinity, alignment: .leading).padding()
                    ForEach(results.songs) { song in
                        Button(action: {
                            hideKeyboard()
                            audioPlayer.startPlayback(from: results.songs, startingWith: song)
                        }) {
                            ListItemView(title: song.title, subtitle: song.artist, detail: song.album, italicizeDetail: true)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }
    
    // Helper functions for playing collections
    private func playArtist(_ artist: Artist) {
        Task {
            let songs = LibraryService.shared.getSongs(forArtist: artist.id)
            if let firstSong = songs.first {
                await MainActor.run {
                    hideKeyboard()
                    audioPlayer.startPlayback(from: songs, startingWith: firstSong)
                }
            }
        }
    }
    
    private func playAlbum(_ album: Album) {
        Task {
            let songs = LibraryService.shared.getSongs(forAlbum: album.id)
            if let firstSong = songs.first {
                await MainActor.run {
                    hideKeyboard()
                    audioPlayer.startPlayback(from: songs, startingWith: firstSong)
                }
            }
        }
    }
    
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
