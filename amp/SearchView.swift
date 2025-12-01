import SwiftUI
import MediaPlayer

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel.shared
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var circleID = UUID() // Force regeneration each time view loads
    @State private var isScrollable = false
    @State private var isAtBottom = false
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchBarView(searchText: $viewModel.searchText)
                    .onChange(of: viewModel.searchText) {
                        viewModel.performSearch()
                    }

                // Separator line below header
                Rectangle()
                    .fill(Theme.primaryText)
                    .frame(height: 2)

                // Content area with conditional circle or search results
                GeometryReader { geometry in
                    ZStack {
                        // Show circle when search is empty or no results
                        if shouldShowCircle {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 300)) // Fixed size to prevent stretching
                                .foregroundStyle(Theme.accentGreen)
                                .id(circleID) // Force regeneration with unique ID
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    hideKeyboard()
                                }
                        }

                        // Show search results when available
                        if hasSearchResults {
                            SearchResultsView(results: viewModel.searchResults, geometry: geometry, isScrollable: $isScrollable, isAtBottom: $isAtBottom, contentHeight: $contentHeight, viewportHeight: $viewportHeight)
                                .environmentObject(audioPlayer)
                        }
                    }
                }

                // The spacer to push content up
                Spacer(minLength: 0)

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

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
                // Text field area with clear button
                HStack(spacing: 8) {
                    TextField("Search Songs, Artists, Albums...", text: $searchText)
                        .focused($isSearchFieldFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            isSearchFieldFocused = false
                        }
                        .font(Theme.bodyFont)

                    // Clear button (only visible when there's text)
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            isSearchFieldFocused = false
                        }) {
                            Image(systemName: "xmark")
                                .foregroundColor(.black)
                                .font(.system(size: 16, weight: .bold))
                        }
                    }
                }
                .padding(.horizontal, 12)

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
    let geometry: GeometryProxy
    @Binding var isScrollable: Bool
    @Binding var isAtBottom: Bool
    @Binding var contentHeight: CGFloat
    @Binding var viewportHeight: CGFloat
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var selectedAlbum: Album?
    @State private var selectedArtist: Artist?

    var body: some View {
        // Use a ScrollView for the stacked-card layout
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    if !results.artists.isEmpty {
                        SearchSectionView(title: "Artists") {
                            ForEach(results.artists) { artist in
                                SearchItemView(
                                    title: artist.name,
                                    subtitle: nil,
                                    detail: nil
                                ) {
                                    hideKeyboard()
                                    selectedArtist = artist
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

                // Invisible anchor at the bottom to track scroll position
                Color.clear
                    .frame(height: 1)
                    .background(
                        GeometryReader { bottomGeometry in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: bottomGeometry.frame(in: .named("search-scroll")).minY
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
        .coordinateSpace(name: "search-scroll")
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
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 20)
        }
        .scrollDismissesKeyboard(.immediately)
        .sheet(item: $selectedAlbum) { album in
            AlbumDetailView(album: album, searchResults: results)
                .environmentObject(audioPlayer)
        }
        .sheet(item: $selectedArtist) { artist in
            ArtistDetailView(artist: artist, searchResults: results)
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
            AlbumDetailHeaderView(albumTitle: album.title, albumArtist: album.artist) {
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

                    // Album name and artist name (moved below artwork)
                    VStack(spacing: 4) {
                        Text(album.title)
                            .font(Theme.sectionHeaderFont)
                            .foregroundColor(Theme.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        Text(album.artist)
                            .font(Theme.bodyFont)
                            .foregroundColor(Theme.primaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16)

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
                        AlbumTracksView(songs: albumSongs, onPlaySong: { song in
                            audioPlayer.startPlayback(from: albumSongs, startingWith: song)
                        })
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

// Header with back button, album name, artist name, and play button
private struct AlbumDetailHeaderView: View {
    let albumTitle: String
    let albumArtist: String
    let backAction: () -> Void
    let playAction: () -> Void
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        HStack(spacing: 12) {
            // Back button with rounded rectangle and drop shadow
            ZStack {
                // Offset shadow layer
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accentDarkBlue)
                    .frame(height: 44)
                    .offset(x: -4, y: 4)

                // Main button container
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
                .frame(height: 44)
                .background(Color.white)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.primaryText, lineWidth: 2)
                )
            }
            .fixedSize()

            // Album name box with rounded rectangle and drop shadow
            ZStack {
                // Offset shadow layer
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accentDarkBlue)
                    .frame(height: 44)
                    .offset(x: -4, y: 4)

                // Main info box container with play button
                Button(action: playAction) {
                    HStack(spacing: 12) {
                        Text(albumTitle)
                            .font(Theme.sectionHeaderFont)
                            .foregroundColor(Theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(height: 44)
                .background(Theme.accentGreen)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.primaryText, lineWidth: 2)
                )
            }
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
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 8)
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
        .aspectRatio(contentMode: .fit)
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
    @State private var enrichedSong: Song?

    private var displaySong: Song {
        enrichedSong ?? song
    }

    private var yearString: String {
        if let releaseDate = displaySong.releaseDate {
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
            AlbumInfoRow(label: "Genre", value: displaySong.genre ?? "Unknown")
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.primaryText, lineWidth: 2))
        .task(id: song.id) {
            // Only enrich if the song doesn't have a release date
            guard song.releaseDate == nil else { return }

            // Enrich song with metadata from audio file (reads ID3 tags)
            enrichedSong = await LibraryService.shared.enrichSongWithFileMetadata(song)
        }
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

// Album tracks view with disc grouping and track numbers
private struct AlbumTracksView: View {
    let songs: [Song]
    let onPlaySong: (Song) -> Void

    // Group songs by disc number
    private var groupedSongs: [(discNumber: Int, songs: [Song])] {
        let grouped = Dictionary(grouping: songs) { $0.discNumber }
        return grouped.sorted { $0.key < $1.key }.map { (discNumber: $0.key, songs: $0.value.sorted { $0.albumTrackNumber < $1.albumTrackNumber }) }
    }

    // Check if this album has multiple discs
    private var hasMultipleDiscs: Bool {
        Set(songs.map { $0.discNumber }).count > 1
    }

    var body: some View {
        SearchSectionView(title: "Tracks") {
            VStack(spacing: -1) {
                ForEach(groupedSongs, id: \.discNumber) { disc in
                    VStack(spacing: -1) {
                        // Show disc header only for multi-disc albums
                        if hasMultipleDiscs {
                            Text("Disc \(disc.discNumber)")
                                .font(Theme.bodyFont.weight(.semibold))
                                .foregroundColor(Theme.primaryText)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 12)
                                .background(Color.white)
                                .overlay(
                                    Rectangle()
                                        .stroke(Theme.primaryText, lineWidth: 1)
                                        .frame(height: 1),
                                    alignment: .bottom
                                )
                        }

                        // Track listing
                        ForEach(disc.songs) { song in
                            TrackItemView(
                                trackNumber: song.albumTrackNumber,
                                title: song.title
                            ) {
                                onPlaySong(song)
                            }
                        }
                    }
                }
            }
        }
    }
}

// Track item with track number prefix
private struct TrackItemView: View {
    let trackNumber: Int
    let title: String
    let action: () -> Void
    @GestureState private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Track number
                Text("\(trackNumber).")
                    .font(Theme.bodyFont.weight(.semibold))
                    .foregroundColor(Theme.primaryText)
                    .frame(width: 30, alignment: .trailing)

                // Track title
                Text(title)
                    .font(Theme.bodyFont)
                    .foregroundColor(Theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isPressed ? Theme.accentYellow : Color.white)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in
                    state = true
                }
        )
    }
}

// MARK: - Artist Detail View

private enum ArtistLoadError: Error {
    case timeout
}

struct ArtistDetailView: View {
    let artist: Artist
    let searchResults: SearchResults
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var artistAlbums: [Album] = []
    @State private var artistSongs: [Song] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedAlbum: Album?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            ArtistDetailHeaderView(artistName: artist.name) {
                dismiss()
            } playAction: {
                playArtist()
            }

            // Separator
            Rectangle()
                .fill(Theme.primaryText)
                .frame(height: 2)

            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Album and Songs sections
                    if isLoading {
                        ProgressView("Loading artist content...")
                            .padding(.top, 40)
                    } else if let error = loadError {
                        VStack(spacing: 8) {
                            Text("Error loading artist content")
                                .font(Theme.bodyFont.weight(.semibold))
                                .foregroundColor(Theme.primaryText)
                            Text(error)
                                .font(Theme.bodyFont)
                                .foregroundColor(Theme.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 40)
                        .padding(.horizontal, 32)
                    } else {
                        // Albums section
                        if !artistAlbums.isEmpty {
                            SearchSectionView(title: "Albums") {
                                ForEach(artistAlbums) { album in
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
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                        }

                        // Songs section (alphabetized)
                        if !artistSongs.isEmpty {
                            SearchSectionView(title: "Songs") {
                                ForEach(artistSongs) { song in
                                    SearchItemView(
                                        title: song.title,
                                        subtitle: song.artist,
                                        detail: song.album,
                                        italicizeDetail: true
                                    ) {
                                        audioPlayer.startPlayback(from: artistSongs, startingWith: song)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, artistAlbums.isEmpty ? 20 : 16)
                        }

                        if artistAlbums.isEmpty && artistSongs.isEmpty {
                            Text("No content found for this artist")
                                .font(Theme.bodyFont)
                                .foregroundColor(Theme.primaryText)
                                .padding(.top, 40)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color.white)
        .sheet(item: $selectedAlbum) { album in
            AlbumDetailView(album: album, searchResults: searchResults)
                .environmentObject(audioPlayer)
        }
        .onAppear {
            print("🎵 ArtistDetailView appeared for artist: \(artist.name) with ID: \(artist.id)")
            loadArtistContent()
        }
    }

    private func loadArtistContent() {
        // Set loading state immediately on main actor
        isLoading = true
        loadError = nil

        Task {
            do {
                print("🔍 DEBUG: Loading content for artist '\(artist.name)' with ID: \(artist.id)")

                // Add a timeout to catch stuck loads
                let (albums, songs) = try await withThrowingTaskGroup(of: (albums: [Album], songs: [Song]).self) { group in
                    // Add the actual load task
                    group.addTask {
                        await Task.detached(priority: .userInitiated) {
                            let albums = LibraryService.shared.getAlbums(forArtist: self.artist.id)
                            let songs = LibraryService.shared.getSongs(forArtist: self.artist.id)
                            return (albums: albums, songs: songs)
                        }.value
                    }

                    // Add a timeout task (5 seconds)
                    group.addTask {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        throw ArtistLoadError.timeout
                    }

                    // Return the first result (either content or timeout)
                    for try await result in group {
                        group.cancelAll()
                        return result
                    }

                    return (albums: [], songs: [])
                }

                print("🔍 DEBUG: Found \(albums.count) albums and \(songs.count) songs for artist '\(artist.name)'")

                // Update UI on main thread
                await MainActor.run {
                    self.artistAlbums = albums
                    // Alphabetize songs by title
                    self.artistSongs = songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    self.isLoading = false
                    print("🔍 DEBUG: Artist content loaded: \(self.artistAlbums.count) albums, \(self.artistSongs.count) songs")
                }
            } catch ArtistLoadError.timeout {
                print("⚠️ Artist load timed out for '\(artist.name)'")
                await MainActor.run {
                    self.loadError = "Loading took too long. Please try again."
                    self.isLoading = false
                }
            } catch {
                print("⚠️ Artist load error for '\(artist.name)': \(error)")
                await MainActor.run {
                    self.loadError = "Failed to load artist content: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    private func playArtist() {
        // Group songs by album
        let songsGroupedByAlbum = Dictionary(grouping: artistSongs) { $0.album }

        // Create array of (album name, songs, release date) tuples
        let albumGroups: [(albumName: String, songs: [Song], releaseDate: Date?)] = songsGroupedByAlbum.map { albumName, songs in
            // Sort songs within each album by track number
            let sortedSongs = songs.sorted { $0.albumTrackNumber < $1.albumTrackNumber }
            // Get release date from first song in album
            let releaseDate = sortedSongs.first?.releaseDate
            return (albumName: albumName, songs: sortedSongs, releaseDate: releaseDate)
        }

        // Check if all albums have release dates
        let allHaveReleaseDates = albumGroups.allSatisfy { $0.releaseDate != nil }

        // Sort albums by release date if all have dates, otherwise alphabetically
        let sortedAlbumGroups: [(albumName: String, songs: [Song], releaseDate: Date?)]
        if allHaveReleaseDates {
            sortedAlbumGroups = albumGroups.sorted { (lhs, rhs) in
                guard let lhsDate = lhs.releaseDate, let rhsDate = rhs.releaseDate else {
                    return false
                }
                return lhsDate < rhsDate
            }
        } else {
            sortedAlbumGroups = albumGroups.sorted { $0.albumName.localizedCaseInsensitiveCompare($1.albumName) == .orderedAscending }
        }

        // Flatten all songs in the sorted order
        let sortedSongs = sortedAlbumGroups.flatMap { $0.songs }

        // Play from the first song
        if let firstSong = sortedSongs.first {
            audioPlayer.startPlayback(from: sortedSongs, startingWith: firstSong)
        }
    }
}

// Header with back button and artist name
private struct ArtistDetailHeaderView: View {
    let artistName: String
    let backAction: () -> Void
    let playAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Back button with rounded rectangle and drop shadow
            ZStack {
                // Offset shadow layer
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accentDarkBlue)
                    .frame(height: 44)
                    .offset(x: -4, y: 4)

                // Main button container
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
                .frame(height: 44)
                .background(Color.white)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.primaryText, lineWidth: 2)
                )
            }
            .fixedSize()

            // Artist name box with rounded rectangle and drop shadow
            ZStack {
                // Offset shadow layer
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accentDarkBlue)
                    .frame(height: 44)
                    .offset(x: -4, y: 4)

                // Main info box container with play button
                Button(action: playAction) {
                    HStack(spacing: 12) {
                        Text(artistName)
                            .font(Theme.sectionHeaderFont)
                            .foregroundColor(Theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(height: 44)
                .background(Theme.accentGreen)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.primaryText, lineWidth: 2)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white)
    }
}
