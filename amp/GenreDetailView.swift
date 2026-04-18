import SwiftUI
import MediaPlayer

// Genre Detail: chrome + centered genre title + Albums / Artists / Songs
// chips (default Albums) + PlayAllBar + yellow section block + filtered
// content. Chip-driven content reuses the same scrubbable views as the
// Library tab, so behaviour (alphabet rail, big-letter indicator) stays
// consistent. Playback triggers stay in place — same convention as
// Album / Playlist / Artist Detail.

struct GenreDetailView: View {
    let genre: String

    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var nav = NavigationService.shared
    @Environment(\.dismiss) private var dismiss

    enum Mode: Hashable { case albums, artists, songs }
    @State private var mode: Mode = .albums

    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var artistAlbumCounts: [MPMediaEntityPersistentID: Int] = [:]
    @State private var songSections: [LetterSection<Song>] = []
    @State private var albumSections: [LetterSection<Album>] = []
    @State private var artistSections: [LetterSection<Artist>] = []

    var body: some View {
        VStack(spacing: 0) {
            chrome
            genreTitle
            filterChipsRow
            sectionHeader
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: genre) {
            await loadData()
        }
    }

    // MARK: - Chrome

    // BackButton + PlayAllBar share the chrome row, same arrangement as
    // Album / Artist / Playlist Detail. PlayAllBar carries a generic
    // "Play all" label here — the genre name already anchors the view
    // below, and the yellow block calls out the active chip's content.
    private var chrome: some View {
        HStack(spacing: 12) {
            BackButton { dismiss() }
            Spacer(minLength: 12)
            PlayAllBar(
                title: "Play all",
                fillsWidth: false,
                onTap: playAll,
                onShuffleLongPress: shufflePlayAll
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private var genreTitle: some View {
        Text(genre)
            .font(.nowPlayingTitle)
            .foregroundStyle(Color.ampBlack)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
    }

    private var filterChipsRow: some View {
        HStack(spacing: 12) {
            FilterChip(label: "Albums", systemIcon: "record.circle.fill", isSelected: mode == .albums, alwaysShowIcon: true) { mode = .albums }
            FilterChip(label: "Artists", systemIcon: "person.wave.2.fill", isSelected: mode == .artists, alwaysShowIcon: true) { mode = .artists }
            FilterChip(label: "Songs", systemIcon: "music.quarternote.3", isSelected: mode == .songs, alwaysShowIcon: true) { mode = .songs }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4) // accommodate brutalist shadow bleed
        .padding(.bottom, 20)
    }

    private var sectionHeader: some View {
        ViewTitleBlock(sectionLabel)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
    }

    private var sectionLabel: String {
        switch mode {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .songs: return "Songs"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .albums: albumsContent
        case .artists: artistsContent
        case .songs: songsContent
        }
    }

    @ViewBuilder
    private var albumsContent: some View {
        if albums.isEmpty {
            emptyState("No albums in this genre.")
        } else {
            AlbumsScrubbableGrid(sections: albumSections)
        }
    }

    @ViewBuilder
    private var artistsContent: some View {
        if artists.isEmpty {
            emptyState("No artists in this genre.")
        } else {
            ArtistsScrubbableList(sections: artistSections, albumCounts: artistAlbumCounts)
        }
    }

    @ViewBuilder
    private var songsContent: some View {
        if songs.isEmpty {
            emptyState("No songs in this genre.")
        } else {
            SongsScrubbableList(sections: songSections) { song in
                playFromSong(song)
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

    // MARK: - Playback
    //
    // All three triggers stay on the Genre Detail view — same convention
    // as Album / Playlist / Artist Detail. Tapping the currently playing
    // row toggles play/pause.

    private func playAll() {
        let ids = songs.map { $0.persistentID }
        guard !ids.isEmpty else { return }
        audioPlayer.startPlayback(fromTrackIDs: ids, startingAt: 0, navigateToNowPlaying: false)
    }

    private func shufflePlayAll() {
        let ids = songs.map { $0.persistentID }.shuffled()
        guard !ids.isEmpty else { return }
        audioPlayer.startPlayback(fromTrackIDs: ids, startingAt: 0, navigateToNowPlaying: false)
    }

    private func playFromSong(_ song: Song) {
        if audioPlayer.currentTrack?.persistentID == song.persistentID {
            audioPlayer.playPause()
            return
        }
        let ids = songs.map { $0.persistentID }
        guard let index = ids.firstIndex(of: song.persistentID) else { return }
        audioPlayer.startPlayback(fromTrackIDs: ids, startingAt: index, navigateToNowPlaying: false)
    }

    // MARK: - Loading

    // One MPMediaQuery pass, dedupe into Song / Album / Artist sets.
    // Artist identity prefers albumArtistPersistentID (canonical) with
    // a fallback to artistPersistentID, matching ArtistDetailView's
    // identity rules.
    private func loadData() async {
        let captured = genre
        let loaded = await Task.detached(priority: .userInitiated) {
            let predicate = MPMediaPropertyPredicate(
                value: captured,
                forProperty: MPMediaItemPropertyGenre,
                comparisonType: .equalTo
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            let items = query.items ?? []

            var songs: [Song] = []
            var albumMap: [MPMediaEntityPersistentID: Album] = [:]
            var artistMap: [MPMediaEntityPersistentID: Artist] = [:]
            var artistAlbums: [MPMediaEntityPersistentID: Set<MPMediaEntityPersistentID>] = [:]

            for item in items {
                songs.append(LibraryService.shared.song(from: item))

                let albumID = item.albumPersistentID
                if albumID != 0, albumMap[albumID] == nil {
                    let title = item.albumTitle ?? ""
                    let artist = item.albumArtist ?? item.artist ?? ""
                    albumMap[albumID] = Album(id: albumID, title: title, artist: artist)
                }

                let artistID = item.albumArtistPersistentID != 0
                    ? item.albumArtistPersistentID
                    : item.artistPersistentID
                if artistID != 0 {
                    if artistMap[artistID] == nil {
                        let name = item.albumArtist ?? item.artist ?? ""
                        artistMap[artistID] = Artist(id: artistID, name: name)
                    }
                    if albumID != 0 {
                        artistAlbums[artistID, default: []].insert(albumID)
                    }
                }
            }

            let sortedSongs = songs.sorted { LibraryService.nameOrder($0.title, $1.title) }
            let sortedAlbums = Array(albumMap.values).sorted { LibraryService.nameOrder($0.title, $1.title) }
            let sortedArtists = Array(artistMap.values).sorted { LibraryService.nameOrder($0.name, $1.name) }
            let counts = artistAlbums.mapValues { $0.count }

            let songSections = LetterSection.bucket(sortedSongs) { $0.title }
            let albumSections = LetterSection.bucket(sortedAlbums) { $0.title }
            let artistSections = LetterSection.bucket(sortedArtists) { $0.name }

            return (sortedSongs, sortedAlbums, sortedArtists, counts, songSections, albumSections, artistSections)
        }.value

        self.songs = loaded.0
        self.albums = loaded.1
        self.artists = loaded.2
        self.artistAlbumCounts = loaded.3
        self.songSections = loaded.4
        self.albumSections = loaded.5
        self.artistSections = loaded.6
    }
}
