import SwiftUI
import MediaPlayer

// Spec §7.1: Library tab root. Yellow LIBRARY title block + gear/search
// chrome buttons, filter chips for Albums / Artists / Playlists, content
// area switches by chip. Tap an album → push Album Detail; tap an artist →
// push Artist Detail; tap a playlist → push Playlist Detail; tap gear →
// push Settings; tap search → switch to the Search tab.

enum LibraryMode { case albums, artists, songs, playlists }

struct LibraryView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var nav = NavigationService.shared

    @State private var mode: LibraryMode = .albums
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var artistAlbumCounts: [MPMediaEntityPersistentID: Int] = [:]
    @State private var isLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            chrome
            filterChipsRow
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard !isLoaded else { return }
            await loadData()
            isLoaded = true
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack(spacing: 12) {
            ViewTitleBlock("LIBRARY")
            ChromeButton(icon: "gear", a11y: "Settings") {
                nav.push(.settings)
            }
            ChromeButton(icon: "magnifyingglass", a11y: "Search") {
                nav.selectedTab = .search
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                FilterChip(label: "Albums", isSelected: mode == .albums) { mode = .albums }
                FilterChip(label: "Artists", isSelected: mode == .artists) { mode = .artists }
                FilterChip(label: "Songs", isSelected: mode == .songs) { mode = .songs }
                FilterChip(label: "Playlists", isSelected: mode == .playlists) { mode = .playlists }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4) // accommodate brutalist shadow bleed
        }
        .padding(.bottom, 20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .albums: albumsGrid
        case .artists: artistsList
        case .songs: songsList
        case .playlists: playlistsList
        }
    }

    private var albumsGrid: some View {
        ScrollView {
            if albums.isEmpty {
                emptyState("No music found.")
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ],
                    spacing: 24
                ) {
                    ForEach(albums) { album in
                        AlbumGridCell(album: album) {
                            nav.push(.albumDetail(album.id))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    // List gives us iOS-native row virtualization with stable sizing (and the
    // hook for §8.5's alphabetic scrubber later). Default list chrome is
    // suppressed so the rows render exactly as the brutalist row primitives
    // define them.
    private var artistsList: some View {
        Group {
            if artists.isEmpty {
                emptyState("No music found.")
            } else {
                ArtistsScrubbableList(
                    artists: artists,
                    albumCounts: artistAlbumCounts
                )
            }
        }
    }

    private var songsList: some View {
        Group {
            if songs.isEmpty {
                emptyState("No music found.")
            } else {
                SongsScrubbableList(songs: songs) { index in
                    let ids = songs.map { $0.persistentID }
                    audioPlayer.startPlayback(fromTrackIDs: ids, startingAt: index)
                }
            }
        }
    }

    private var playlistsList: some View {
        Group {
            if playlists.isEmpty {
                emptyState("No playlists found.")
            } else {
                List(playlists) { playlist in
                    PlaylistListRow(name: playlist.name) {
                        nav.push(.playlistDetail(playlist.id))
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.ampWhite)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.ampWhite)
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.metadata)
            .foregroundStyle(Color.ampMutedText)
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
    }

    // MARK: - Data loading

    private func loadData() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            let albums = LibraryService.shared.getAllAlbums()
            let artistRows = LibraryService.shared.getAllArtistsWithAlbumCounts()
            let songs = LibraryService.shared.getAllSongs()
            let playlists = LibraryService.shared.getPlaylists()

            let artists = artistRows.map { $0.artist }
            var counts: [MPMediaEntityPersistentID: Int] = [:]
            for row in artistRows {
                counts[row.artist.id] = row.albumCount
            }
            return (albums, artists, songs, playlists, counts)
        }.value

        self.albums = loaded.0
        self.artists = loaded.1
        self.songs = loaded.2
        self.playlists = loaded.3
        self.artistAlbumCounts = loaded.4
    }
}

// MARK: - Private components

// Artists list with alphabet scrubber (spec §8.5). Pulled out of
// LibraryView so the sectioning, rail, and indicator logic stays
// focused. Albums grid + Songs list don't get the scrubber yet —
// grid UX is a separate consideration, and Songs doesn't currently
// sort alphabetically by title.

private struct ArtistsScrubbableList: View {
    let artists: [Artist]
    let albumCounts: [MPMediaEntityPersistentID: Int]

    @ObservedObject private var nav = NavigationService.shared

    @State private var draggedLetter: String?
    @State private var indicatorDismissTask: Task<Void, Never>?

    private var sections: [(letter: String, artists: [Artist])] {
        let grouped = Dictionary(grouping: artists) { AlphabetSectioning.key(for: $0.name) }
        return AlphabetSectioning.sortedKeys(grouped.keys).map { letter in
            (letter: letter, artists: grouped[letter] ?? [])
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                List {
                    ForEach(sections, id: \.letter) { section in
                        Section {
                            ForEach(section.artists) { artist in
                                ArtistRow(
                                    name: artist.name,
                                    albumCount: albumCounts[artist.id] ?? 0
                                ) {
                                    nav.push(.artistDetail(artist.id))
                                }
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.ampWhite)
                            }
                        } header: {
                            Text(section.letter)
                                .font(.custom("AtkinsonHyperlegibleMono-Bold", size: 11))
                                .foregroundStyle(Color.ampMutedText)
                                .padding(.leading, 24)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.ampWhite)
                                .listRowInsets(EdgeInsets())
                        }
                        .id(section.letter)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.ampWhite)

                AlphabetScrubber(
                    letters: sections.map { $0.letter },
                    onLetterChanged: { letter in
                        indicatorDismissTask?.cancel()
                        draggedLetter = letter
                        proxy.scrollTo(letter, anchor: .top)
                    },
                    onDragEnded: {
                        indicatorDismissTask?.cancel()
                        indicatorDismissTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            draggedLetter = nil
                        }
                    }
                )
                .padding(.trailing, 4)

                if let letter = draggedLetter {
                    BigLetterIndicator(letter: letter)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.clear)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
    }
}

// Songs list with the same alphabet-scrubber pattern as Artists.
// Songs are sorted by title (MPMediaQuery returns them in
// artist/album/track order by default). Sections keyed on first letter.

private struct SongsScrubbableList: View {
    let songs: [Song]
    let onPlay: (Int) -> Void

    @State private var draggedLetter: String?
    @State private var indicatorDismissTask: Task<Void, Never>?

    // Pre-sorted and flattened with original indices so the tap callback
    // still plays from the same queue position the list displays.
    private var sortedSongs: [(originalIndex: Int, song: Song)] {
        songs.enumerated()
            .map { ($0.offset, $0.element) }
            .sorted { a, b in
                a.song.title.localizedCaseInsensitiveCompare(b.song.title) == .orderedAscending
            }
    }

    private var sections: [(letter: String, items: [(originalIndex: Int, song: Song)])] {
        let grouped = Dictionary(grouping: sortedSongs) { AlphabetSectioning.key(for: $0.song.title) }
        return AlphabetSectioning.sortedKeys(grouped.keys).map { letter in
            (letter: letter, items: grouped[letter] ?? [])
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                List {
                    ForEach(sections, id: \.letter) { section in
                        Section {
                            ForEach(section.items, id: \.originalIndex) { entry in
                                SongResultRow(
                                    title: entry.song.title,
                                    artist: entry.song.artist,
                                    album: entry.song.album,
                                    duration: "",
                                    onTap: { onPlay(entry.originalIndex) },
                                    onLongPress: {
                                        NavigationService.shared.navigateToAlbum(forTrack: entry.song.persistentID)
                                    }
                                )
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.ampWhite)
                            }
                        } header: {
                            sectionHeader(section.letter)
                        }
                        .id(section.letter)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.ampWhite)

                AlphabetScrubber(
                    letters: sections.map { $0.letter },
                    onLetterChanged: { letter in
                        indicatorDismissTask?.cancel()
                        draggedLetter = letter
                        proxy.scrollTo(letter, anchor: .top)
                    },
                    onDragEnded: {
                        indicatorDismissTask?.cancel()
                        indicatorDismissTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            draggedLetter = nil
                        }
                    }
                )
                .padding(.trailing, 4)

                if let letter = draggedLetter {
                    BigLetterIndicator(letter: letter)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.clear)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func sectionHeader(_ letter: String) -> some View {
        Text(letter)
            .font(.custom("AtkinsonHyperlegibleMono-Bold", size: 11))
            .foregroundStyle(Color.ampMutedText)
            .padding(.leading, 24)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ampWhite)
            .listRowInsets(EdgeInsets())
    }
}

private struct ChromeButton: View {
    let icon: String
    let a11y: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.ampBlack)
                .frame(width: 44, height: 44)
                .background(Color.ampWhite)
                .brutalistStroke()
                .brutalistShadow(.small)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
    }
}

// Spec §7.1 Albums grid: square art with 2px stroke, NO offset shadow (art is
// content per §4). Caption: title (sans bold) + artist (sans regular muted).
private struct AlbumGridCell: View {
    let album: Album
    let onTap: () -> Void

    @State private var artwork: UIImage?

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                art
                    .aspectRatio(1, contentMode: .fit)
                    .brutalistStroke()
                Text(album.title)
                    .font(.listTitle)
                    .foregroundStyle(Color.ampBlack)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.subtitle)
                    .foregroundStyle(Color.ampMutedText)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(album.title) by \(album.artist)")
        .task(id: album.id) {
            await loadArtwork()
        }
    }

    @ViewBuilder
    private var art: some View {
        if let artwork {
            Image(uiImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(Color.ampNavy)
                Text(String(album.title.prefix(1)).uppercased())
                    .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 48))
                    .foregroundStyle(Color.ampWhite)
            }
        }
    }

    private func loadArtwork() async {
        let id = album.id
        let image = await Task.detached(priority: .userInitiated) {
            LibraryService.shared.getArtworkImage(
                forAlbum: id,
                size: CGSize(width: 300, height: 300)
            )
        }.value
        self.artwork = image
    }
}

private struct PlaylistListRow: View {
    let name: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(name)
                .font(.listTitle)
                .foregroundStyle(Color.ampBlack)
                .lineLimit(1)
                .padding(.leading, 24)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .center)
        .background(Color.ampWhite)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ampDivider)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    LibraryView()
}
