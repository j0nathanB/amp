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
    @State private var selectedAlbum: Album?

    var body: some View {
        // Use a ScrollView for the stacked-card layout
        ScrollView {
            VStack(spacing: 16) {
                if !results.artists.isEmpty {
                    SearchSectionView(title: "Artists") {
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
                }

                if !results.albums.isEmpty {
                    SearchSectionView(title: "Albums") {
                        ForEach(results.albums) { album in
                            SearchItemView(
                                title: album.title,
                                subtitle: album.artist,
                                detail: nil,
                                italicizeTitle: true
                            ) {
                                selectedAlbum = album
                            }
                        }
                    }
                }

                if !results.songs.isEmpty {
                    SearchSectionView(title: "Songs") {
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
            .padding(.horizontal, 16)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 20)
        }
        .scrollDismissesKeyboard(.immediately)
        .sheet(item: $selectedAlbum) { album in
            AlbumDetailView(album: album, searchResults: results)
                .environmentObject(audioPlayer)
        }
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

// Search section container with green header and border
private struct SearchSectionView<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            // Green header
            Text(title)
                .font(Theme.sectionHeaderFont)
                .foregroundColor(Theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.accentGreen)

            // Content with negative spacing for border overlap
            VStack(spacing: -1) {
                content
            }
            .background(Color.white)
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.primaryText, lineWidth: 2)
        )
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

// MARK: - Album Detail View

private enum AlbumLoadError: Error {
    case timeout
}

struct AlbumDetailView: View {
    let album: Album
    let searchResults: SearchResults
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var albumSongs: [Song] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            AlbumDetailHeaderView(albumTitle: album.title) {
                dismiss()
            } playAction: {
                playAlbum()
            }

            // Separator
            Rectangle()
                .fill(Theme.primaryText)
                .frame(height: 2)

            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Album artwork and info
                    AlbumArtworkSection(album: album, songs: albumSongs)
                        .padding(.top, 20)

                    // Track listing or loading/empty state
                    if isLoading {
                        ProgressView("Loading tracks...")
                            .padding(.top, 40)
                    } else if let error = loadError {
                        VStack(spacing: 8) {
                            Text("Error loading tracks")
                                .font(Theme.bodyFont.weight(.semibold))
                                .foregroundColor(Theme.primaryText)
                            Text(error)
                                .font(Theme.bodyFont)
                                .foregroundColor(Theme.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 40)
                        .padding(.horizontal, 32)
                    } else if !albumSongs.isEmpty {
                        SearchSectionView(title: "Tracks") {
                            ForEach(albumSongs) { song in
                                SearchItemView(
                                    title: song.title,
                                    subtitle: song.artist,
                                    detail: song.album,
                                    italicizeDetail: true
                                ) {
                                    audioPlayer.startPlayback(from: albumSongs, startingWith: song)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        Text("No tracks found for this album")
                            .font(Theme.bodyFont)
                            .foregroundColor(Theme.primaryText)
                            .padding(.top, 40)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color.white)
        .onAppear {
            print("🎵 AlbumDetailView appeared for album: \(album.title) with ID: \(album.id)")
            loadAlbumSongs()
        }
    }

    private func loadAlbumSongs() {
        // Set loading state immediately on main actor
        isLoading = true
        loadError = nil

        Task {
            do {
                print("🔍 DEBUG: Loading songs for album '\(album.title)' with ID: \(album.id)")

                // Add a timeout to catch stuck loads
                let songs = try await withThrowingTaskGroup(of: [Song].self) { group in
                    // Add the actual load task
                    group.addTask {
                        await Task.detached(priority: .userInitiated) {
                            LibraryService.shared.getSongs(forAlbum: self.album.id)
                        }.value
                    }

                    // Add a timeout task (5 seconds)
                    group.addTask {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        throw AlbumLoadError.timeout
                    }

                    // Return the first result (either songs or timeout)
                    for try await result in group {
                        group.cancelAll()
                        return result
                    }

                    return []
                }

                print("🔍 DEBUG: Found \(songs.count) songs for album '\(album.title)'")

                // Update UI on main thread
                await MainActor.run {
                    let sortedSongs = songs.sorted { $0.albumTrackNumber < $1.albumTrackNumber }
                    self.albumSongs = sortedSongs
                    self.isLoading = false
                    print("🔍 DEBUG: Album songs loaded and UI updated: \(self.albumSongs.count) songs")
                }
            } catch AlbumLoadError.timeout {
                print("⚠️ Album load timed out for '\(album.title)'")
                await MainActor.run {
                    self.loadError = "Loading took too long. Please try again."
                    self.isLoading = false
                }
            } catch {
                print("⚠️ Album load error for '\(album.title)': \(error)")
                await MainActor.run {
                    self.loadError = "Failed to load album tracks: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    private func playAlbum() {
        if let firstSong = albumSongs.first {
            audioPlayer.startPlayback(from: albumSongs, startingWith: firstSong)
        }
    }
}

// Header with back button, "Album" label, and play button
private struct AlbumDetailHeaderView: View {
    let albumTitle: String
    let backAction: () -> Void
    let playAction: () -> Void
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        HStack(spacing: 12) {
            // Back button
            Button(action: backAction) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                    Text("Back")
                        .font(Theme.bodyFont)
                }
                .foregroundColor(Theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // "Album" label
            Text("Album")
                .font(Theme.sectionHeaderFont)
                .foregroundColor(Theme.primaryText)

            Spacer()

            // Play button (similar to ListItemView)
            Button(action: playAction) {
                ZStack {
                    Rectangle()
                        .fill(Theme.accentGreen)
                        .frame(width: 60, height: 60)

                    Image(systemName: "play.fill")
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .overlay(
                Rectangle()
                    .stroke(Theme.primaryText, lineWidth: 2)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white)
    }
}

// Album artwork section with tap-to-show-info functionality
private struct AlbumArtworkSection: View {
    let album: Album
    let songs: [Song]
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 16) {
            // Album artwork (or info view)
            Group {
                if showInfo, let firstSong = songs.first {
                    AlbumDetailInfoView(album: album, song: firstSong)
                        .onTapGesture {
                            showInfo = false
                        }
                } else {
                    AlbumArtworkImage(albumID: album.id)
                        .onTapGesture {
                            showInfo = true
                        }
                }
            }
            .frame(width: 375, height: 375)

            // Album title and artist
            VStack(spacing: 4) {
                Text(album.title)
                    .font(Theme.searchAlbumFont)
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(album.artist)
                    .font(Theme.bodyFont)
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
        }
    }
}

// Album artwork image component
private struct AlbumArtworkImage: View {
    let albumID: MPMediaEntityPersistentID
    @State private var artwork: UIImage?

    var body: some View {
        Group {
            if let image = artwork {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "circle.fill")
                    .resizable()
                    .padding(70)
                    .foregroundStyle(Theme.accentGreen)
            }
        }
        .frame(width: 375, height: 375)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.primaryText, lineWidth: 2))
        .onAppear {
            loadArtwork()
        }
    }

    private func loadArtwork() {
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: albumID), forProperty: MPMediaItemPropertyAlbumPersistentID)
        let query = MPMediaQuery.albums()
        query.addFilterPredicate(predicate)
        print("🔍 DEBUG: Loading artwork for album ID: \(albumID)")
        print("🔍 DEBUG: Query returned \(query.items?.count ?? 0) items")
        artwork = query.items?.first?.artwork?.image(at: CGSize(width: 500, height: 500))
        print("🔍 DEBUG: Artwork loaded: \(artwork != nil)")
    }
}

// Album info view (shown when tapping artwork)
private struct AlbumDetailInfoView: View {
    let album: Album
    let song: Song

    private var yearString: String {
        if let releaseDate = song.releaseDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy"
            return formatter.string(from: releaseDate)
        }
        return "Unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AlbumInfoRow(label: "Album", value: album.title)
            AlbumInfoRow(label: "Artist", value: album.artist)
            AlbumInfoRow(label: "Year", value: yearString)
            AlbumInfoRow(label: "Genre", value: song.genre ?? "Unknown")
        }
        .padding(22)
        .frame(width: 375, height: 375)
        .background(Color.white)
        .overlay(Rectangle().stroke(Theme.primaryText, lineWidth: 2))
    }
}

private struct AlbumInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text("\(label):")
                .font(Theme.bodyFont.weight(.semibold))
                .foregroundColor(Theme.primaryText)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(Theme.bodyFont)
                .foregroundColor(Theme.primaryText)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
