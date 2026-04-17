import SwiftUI
import MediaPlayer

// Spec §7.5: pushed view from Library / Search. Back button + PlayAllBar
// carrying the artist name, yellow Albums block + AlbumRow list, yellow
// Songs block + SongResultRow list. Whole view scrolls.
//
// The artistID carried in AmpRoute.artistDetail is an
// albumArtistPersistentID (canonical identity from the new Library artist
// list), so we use getAlbums/Songs(forAlbumArtist:) for lookups.

struct ArtistDetailView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var nav = NavigationService.shared
    @Environment(\.dismiss) private var dismiss

    let artistID: MPMediaEntityPersistentID

    @State private var artistName: String = ""
    @State private var albums: [Album] = []
    @State private var songs: [Song] = []
    @State private var albumTrackCounts: [MPMediaEntityPersistentID: Int] = [:]
    @State private var albumYears: [MPMediaEntityPersistentID: Int] = [:]
    @State private var durations: [MPMediaEntityPersistentID: TimeInterval] = [:]

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(spacing: 0) {
                    artistTitle
                        .padding(.bottom, 16)

                    ViewTitleBlock("Albums")
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                    albumsList
                        .padding(.bottom, 24)

                    ViewTitleBlock("Songs")
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                    songsList
                }
                .padding(.bottom, 24)
            }
            .overflowGradientBars()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: artistID) {
            await loadData()
        }
    }

    // MARK: - Chrome

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

    private var artistTitle: some View {
        Text(artistName.isEmpty ? "…" : artistName)
            .font(.nowPlayingTitle)
            .foregroundStyle(Color.ampBlack)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
    }

    // MARK: - Sections

    private var albumsList: some View {
        VStack(spacing: 0) {
            ForEach(albums) { album in
                ArtistAlbumRow(
                    album: album,
                    year: albumYears[album.id],
                    trackCount: albumTrackCounts[album.id] ?? 0,
                    onTap: {
                        nav.push(.albumDetail(album.id))
                    }
                )
            }
        }
    }

    private var songsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                SongResultRow(
                    title: song.title,
                    artist: song.artist,
                    album: song.album,
                    duration: formatDuration(durations[song.persistentID] ?? 0),
                    isCurrent: audioPlayer.currentTrack?.persistentID == song.persistentID,
                    onTap: { playFromIndex(index) }
                )
            }
        }
    }

    // MARK: - Playback
    //
    // All three triggers stay on the Artist Detail view. Tapping the
    // currently playing row toggles play/pause — same convention as the
    // Queue tab and Album / Playlist Detail.

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

    private func playFromIndex(_ index: Int) {
        guard index >= 0, index < songs.count else { return }
        let tappedID = songs[index].persistentID
        if audioPlayer.currentTrack?.persistentID == tappedID {
            audioPlayer.playPause()
            return
        }
        let ids = songs.map { $0.persistentID }
        audioPlayer.startPlayback(fromTrackIDs: ids, startingAt: index, navigateToNowPlaying: false)
    }

    // MARK: - Loading

    private func loadData() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            // AmpRoute.artistDetail carries different ID flavors depending on
            // the caller: Library's artist list is grouped by
            // albumArtistPersistentID (canonical), while SearchIndexService
            // keys artists by artistPersistentID. For most tracks the two
            // are the same value, but not always — fall back to the other
            // predicate when the first returns empty so the view works for
            // both entry points.
            var albums = LibraryService.shared.getAlbums(forAlbumArtist: artistID)
            var songs = LibraryService.shared.getSongs(forAlbumArtist: artistID)
            if albums.isEmpty && songs.isEmpty {
                albums = LibraryService.shared.getAlbums(forArtist: artistID)
                songs = LibraryService.shared.getSongs(forArtist: artistID)
            }
            let name = songs.first?.artist ?? albums.first?.artist ?? ""

            var albumTrackCounts: [MPMediaEntityPersistentID: Int] = [:]
            var albumYears: [MPMediaEntityPersistentID: Int] = [:]
            for album in albums {
                let albumSongs = LibraryService.shared.getSongs(forAlbum: album.id)
                albumTrackCounts[album.id] = albumSongs.count
                if let date = albumSongs.first?.releaseDate {
                    albumYears[album.id] = Calendar.current.component(.year, from: date)
                }
            }

            var durations: [MPMediaEntityPersistentID: TimeInterval] = [:]
            for song in songs {
                durations[song.persistentID] = LibraryService.shared.getDuration(forTrack: song.persistentID)
            }

            return (name, albums, songs, albumTrackCounts, albumYears, durations)
        }.value

        self.artistName = loaded.0
        self.albums = loaded.1
        self.songs = loaded.2
        self.albumTrackCounts = loaded.3
        self.albumYears = loaded.4
        self.durations = loaded.5
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// AlbumRow takes a UIImage?; load it per-row here so each row owns its
// own artwork state without blocking the artist-level loadData pass.
// Mirrors AlbumGridCell's approach in LibraryView.

private struct ArtistAlbumRow: View {
    let album: Album
    let year: Int?
    let trackCount: Int
    let onTap: () -> Void

    @State private var artwork: UIImage?

    var body: some View {
        AlbumRow(
            artwork: artwork,
            title: album.title,
            year: year,
            trackCount: trackCount,
            onTap: onTap
        )
        .task(id: album.id) {
            let id = album.id
            let image = await Task.detached(priority: .userInitiated) {
                LibraryService.shared.getArtworkImage(
                    forAlbum: id,
                    size: CGSize(width: 128, height: 128)
                )
            }.value
            self.artwork = image
        }
    }
}
