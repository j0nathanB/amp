import SwiftUI
import MediaPlayer

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var circleID = UUID() // Force regeneration each time view loads

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom header with controlled spacing
//                Text("Search")
//                    .font(Theme.titleFont)
//                    .foregroundColor(Theme.primaryText)
//                    .frame(maxWidth: .infinity, alignment: .leading)
//                    .padding(.vertical, 20)
//                    .padding(.horizontal, 16)
//                    .background(Theme.background)

                SearchBarView(searchText: $viewModel.searchText)
                    .onChange(of: viewModel.searchText) {
                        viewModel.performSearch()
                    }

                // Separator line below header
                Rectangle()
                    .fill(Theme.primaryText)
                    .frame(height: 2)

                // Content area with conditional circle or search results
                ZStack {
                    // Show circle when search is empty or no results
                    if shouldShowCircle {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 300)) // Fixed size to prevent stretching
                            .foregroundStyle(Theme.accentGreen)
                            .id(circleID) // Force regeneration with unique ID
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Show search results when available
                    if hasSearchResults {
                        SearchResultsView(results: viewModel.searchResults)
                            .environmentObject(audioPlayer)
                    }
                }

                // The spacer to push the tab bar to the bottom
                Spacer(minLength: 0)
            }
            .navigationBarHidden(true)
            .onAppear {
                // Regenerate circle ID each time view appears
                circleID = UUID()
            }
        }
    }
    
    // Computed properties for conditional display
    private var shouldShowCircle: Bool {
        viewModel.searchText.isEmpty || !hasSearchResults
    }
    
    private var hasSearchResults: Bool {
        !viewModel.searchResults.artists.isEmpty ||
        !viewModel.searchResults.albums.isEmpty ||
        !viewModel.searchResults.songs.isEmpty
    }
}

struct SearchBarView: View {
    @Binding var searchText: String
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        ZStack {
            // Offset shadow layer
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.accentDarkBlue)
                .frame(height: 44) // Match main container height
                .offset(x: -6, y: 6)

            // Main search bar container
            HStack(spacing: 0) {
                // Text field area
                TextField("Search Songs, Artists, Albums...", text: $searchText)
                    .focused($isSearchFieldFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        isSearchFieldFocused = false
                    }
                    .padding(.horizontal, 12)
                    .font(Theme.bodyFont)

                // Separator line between text field and button
                Rectangle()
                    .fill(Theme.primaryText)
                    .frame(width: 1)

                // Magnifying glass button
                Button(action: {
                    // Dismiss keyboard when search button is tapped
                    isSearchFieldFocused = false
                }) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Theme.primaryText)
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .background(Theme.accentYellow)
            }
            .frame(height: 44) // Constrain entire HStack height
            .background(.white)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.primaryText, lineWidth: 2)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12) // Add vertical padding around the entire search bar
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
                        SearchItemView(
                            title: artist.name,
                            subtitle: nil,
                            detail: nil
                        ) {
                            playArtist(artist)
                        }
                    }
                }
                
                if !results.albums.isEmpty {
                    Text("Albums").font(Theme.sectionHeaderFont).frame(maxWidth: .infinity, alignment: .leading).padding()
                    ForEach(results.albums) { album in
                        SearchItemView(
                            title: album.title,
                            subtitle: album.artist,
                            detail: nil,
                            italicizeTitle: true
                        ) {
                            playAlbum(album)
                        }
                    }
                }
                
                if !results.songs.isEmpty {
                    Text("Songs").font(Theme.sectionHeaderFont).frame(maxWidth: .infinity, alignment: .leading).padding()
                    ForEach(results.songs) { song in
                        SearchItemView(
                            title: song.title,
                            subtitle: song.artist,
                            detail: song.album,
                            italicizeDetail: true
                        ) {
                            hideKeyboard()
                            audioPlayer.startPlayback(from: results.songs, startingWith: song)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 20)
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

// Search item with press state
private struct SearchItemView: View {
    let title: String
    let subtitle: String?
    let detail: String?
    var italicizeTitle: Bool = false
    var italicizeDetail: Bool = false
    let action: () -> Void
    @GestureState private var isPressed = false
    
    var body: some View {
        ListItemView(
            title: title,
            subtitle: subtitle,
            detail: detail,
            italicizeTitle: italicizeTitle,
            italicizeDetail: italicizeDetail,
            isPressed: isPressed
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
