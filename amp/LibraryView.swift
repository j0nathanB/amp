import SwiftUI
import MediaPlayer

// Spec §7.1: Library tab root. Yellow LIBRARY title block + gear/search
// chrome buttons, filter chips for Albums / Artists / Playlists, content
// area switches by chip. Tap an album → push Album Detail; tap an artist →
// push Artist Detail; tap a playlist → push Playlist Detail; tap gear →
// push Settings; tap search → switch to the Search tab.

enum LibraryMode { case albums, artists, songs, genres, playlists }

struct LibraryView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var nav = NavigationService.shared
    @ObservedObject private var store = LibraryStore.shared

    @State private var mode: LibraryMode = .albums

    var body: some View {
        VStack(spacing: 0) {
            chrome
            modeTitle
            filterChipsRow
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: mode) {
            await loadForMode(mode)
        }
    }

    private func loadForMode(_ mode: LibraryMode) async {
        switch mode {
        case .albums: await store.ensureAlbums()
        case .artists: await store.ensureArtists()
        case .songs: await store.ensureSongs()
        case .genres: await store.ensureGenres()
        case .playlists: await store.ensurePlaylists()
        }
    }

    // The mode title above the chips labels the current filter — same
    // treatment Genre Detail gives the genre name. With the title doing
    // that job, chips can stay icon-only in both states (alwaysShowIcon
    // on filterChipsRow) instead of expanding the selected one.
    private var modeTitle: some View {
        Text(modeLabel)
            .font(.nowPlayingTitle)
            .foregroundStyle(Color.ampBlack)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
    }

    private var modeLabel: String {
        switch mode {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .songs: return "Songs"
        case .genres: return "Genres"
        case .playlists: return "Playlists"
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack(spacing: 12) {
            ViewTitleBlock("LIBRARY")
            ChromeButton(icon: "gearshape", a11y: "Settings") {
                nav.push(.settings)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private var filterChipsRow: some View {
        HStack(spacing: 12) {
            FilterChip(label: "Albums", systemIcon: "record.circle.fill", isSelected: mode == .albums, alwaysShowIcon: true) { mode = .albums }
            FilterChip(label: "Artists", systemIcon: "person.wave.2.fill", isSelected: mode == .artists, alwaysShowIcon: true) { mode = .artists }
            FilterChip(label: "Songs", systemIcon: "music.quarternote.3", isSelected: mode == .songs, alwaysShowIcon: true) { mode = .songs }
            FilterChip(label: "Genres", systemIcon: "xmark.triangle.circle.square.fill", isSelected: mode == .genres, alwaysShowIcon: true) { mode = .genres }
            FilterChip(label: "Playlists", systemIcon: "radio.fill", isSelected: mode == .playlists, alwaysShowIcon: true) { mode = .playlists }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4) // accommodate brutalist shadow bleed
        .padding(.bottom, 20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .albums: albumsGrid
        case .artists: artistsList
        case .songs: songsList
        case .genres: genresList
        case .playlists: playlistsList
        }
    }

    private var albumsGrid: some View {
        tabContent(state: store.albumsState, isEmpty: store.albums.isEmpty, emptyText: "No music found.") {
            AlbumsScrubbableGrid(sections: store.albumSections)
        }
    }

    private var artistsList: some View {
        tabContent(state: store.artistsState, isEmpty: store.artists.isEmpty, emptyText: "No music found.") {
            ArtistsScrubbableList(
                sections: store.artistSections,
                albumCounts: store.artistAlbumCounts
            )
        }
    }

    private var songsList: some View {
        tabContent(state: store.songsState, isEmpty: store.songs.isEmpty, emptyText: "No music found.") {
            SongsScrubbableList(sections: store.songSections) { song in
                let ids = store.songs.map { $0.persistentID }
                guard let index = ids.firstIndex(of: song.persistentID) else { return }
                audioPlayer.startPlayback(fromTrackIDs: ids, startingAt: index)
            }
        }
    }

    private var genresList: some View {
        tabContent(state: store.genresState, isEmpty: store.genres.isEmpty, emptyText: "No genres found.") {
            GenresScrubbableList(sections: store.genreSections)
        }
    }

    private var playlistsList: some View {
        tabContent(state: store.playlistsState, isEmpty: store.playlists.isEmpty, emptyText: "No playlists found.") {
            List(store.playlists) { playlist in
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
            .overflowGradientBars()
        }
    }

    // Distinguish "still loading" from "loaded but empty" so the brief
    // background-load window doesn't flash the misleading "No music found"
    // message. Shows a ProgressView during load.
    @ViewBuilder
    private func tabContent<Content: View>(
        state: LibraryStore.LoadState,
        isEmpty: Bool,
        emptyText: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        switch state {
        case .idle, .loading:
            EqualizerBars()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if isEmpty {
                emptyState(emptyText)
            } else {
                content()
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

}

// MARK: - Private components

// Artists list with alphabet scrubber (spec §8.5). Pulled out of
// LibraryView so the sectioning, rail, and indicator logic stays
// focused. Songs / Genres / Albums mirror the same pattern below.
// Reused by GenreDetailView.

struct ArtistsScrubbableList: View {
    let sections: [LetterSection<Artist>]
    let albumCounts: [MPMediaEntityPersistentID: Int]

    @ObservedObject private var nav = NavigationService.shared

    @State private var draggedLetter: String?
    @State private var indicatorDismissTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                // ScrollView+LazyVStack instead of List: List eagerly builds
                // an identity map over every row on first display, which
                // stalled the main thread for ~1s when 1400+ artists arrived
                // in one @Published update (profiled 2026-04-17). LazyVStack
                // only materializes rows that enter the viewport.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.items) { artist in
                                    ArtistRow(
                                        name: artist.name,
                                        albumCount: albumCounts[artist.id] ?? 0
                                    ) {
                                        nav.push(.artistDetail(artist.id))
                                    }
                                }
                            } header: {
                                Text(section.letter)
                                    .font(.custom("AtkinsonHyperlegibleMono-Bold", size: 14))
                                    .foregroundStyle(Color.ampMutedText)
                                    .padding(.leading, 24)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.ampWhite)
                            }
                            .id(section.letter)
                        }
                    }
                }
                .background(Color.ampWhite)
                .overflowGradientBars()

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
// Reused by GenreDetailView.
//
// The audio-player binding drives the currently-playing row highlight.
// The onPlay callback owns the playback semantics — callers decide
// whether to navigate to Now Playing (Library) or stay in place
// (GenreDetail).

struct SongsScrubbableList: View {
    // Sections are pre-sorted + pre-grouped upstream (LibraryStore /
    // GenreDetailView). The callback receives the tapped Song so callers
    // decide how to map back to a queue position — avoids passing the
    // full songs array through just for index accounting.
    let sections: [LetterSection<Song>]
    let onPlay: (Song) -> Void

    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var draggedLetter: String?
    @State private var indicatorDismissTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                // ScrollView+LazyVStack instead of List for the same reason
                // as ArtistsScrubbableList: List builds its identity map
                // eagerly on first display, and the 23k songs made the tab
                // take seconds to appear. LazyVStack materializes only the
                // rows entering the viewport.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.items) { song in
                                    SongResultRow(
                                        title: song.title,
                                        artist: song.artist,
                                        album: song.album,
                                        duration: "",
                                        isCurrent: audioPlayer.currentTrack?.persistentID == song.persistentID,
                                        onTap: { onPlay(song) },
                                        onLongPress: {
                                            NavigationService.shared.navigateToAlbum(forTrack: song.persistentID)
                                        }
                                    )
                                }
                            } header: {
                                sectionHeader(section.letter)
                            }
                            .id(section.letter)
                        }
                    }
                }
                .background(Color.ampWhite)
                .overflowGradientBars()

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
            .font(.custom("AtkinsonHyperlegibleMono-Bold", size: 14))
            .foregroundStyle(Color.ampMutedText)
            .padding(.leading, 24)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ampWhite)
    }
}

// Genres list with the same alphabet-scrubber pattern as Artists / Songs.

private struct GenresScrubbableList: View {
    let sections: [LetterSection<String>]

    @ObservedObject private var nav = NavigationService.shared

    @State private var draggedLetter: String?
    @State private var indicatorDismissTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items, id: \.self) { genre in
                                PlaylistListRow(name: genre) {
                                    nav.push(.genreDetail(genre))
                                }
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.ampWhite)
                            }
                        } header: {
                            Text(section.letter)
                                .font(.custom("AtkinsonHyperlegibleMono-Bold", size: 14))
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
                .overflowGradientBars()

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
}

// Albums grid with the same alphabet-scrubber pattern. Albums arrive
// pre-sorted (LibraryService.albumTitleOrder — leading punctuation
// stripped, "#" bucket first). Each letter section renders its own
// LazyVGrid so the letter header above the grid anchors ScrollViewReader's
// scrollTo. Non-alphabetic leading chars bucket into "#".
// Reused by GenreDetailView.

struct AlbumsScrubbableGrid: View {
    let sections: [LetterSection<Album>]

    @ObservedObject private var nav = NavigationService.shared

    @State private var draggedLetter: String?
    @State private var indicatorDismissTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            sectionHeader(section.letter)
                                .id(section.letter)

                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 16),
                                    GridItem(.flexible(), spacing: 16)
                                ],
                                spacing: 24
                            ) {
                                ForEach(section.items) { album in
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
                .background(Color.ampWhite)
                .overflowGradientBars()

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
            .font(.custom("AtkinsonHyperlegibleMono-Bold", size: 14))
            .foregroundStyle(Color.ampMutedText)
            .padding(.leading, 24)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ampWhite)
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
        }
        .buttonStyle(BrutalistButtonStyle(offset: .small, fillColor: .ampWhite))
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
                    .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 58))
                    .foregroundStyle(Color.ampWhite)
            }
        }
    }

    private func loadArtwork() async {
        // 300pt is not arbitrary: MPMediaItemArtwork appears to cache
        // thumbnails at a handful of stock sizes, and 300pt hits one
        // while 200pt forces on-the-fly downscaling from the master
        // (profiled on-device: 200pt → ~580ms, 300pt → ~200ms).
        self.artwork = await ArtworkCache.shared.artwork(
            forAlbum: album.id,
            size: CGSize(width: 300, height: 300)
        )
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
