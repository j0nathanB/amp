import SwiftUI
import MediaPlayer

// Spec §7.4: pushed view from Library / Search / Artist Detail. Back button
// + PlayAllBar carrying the album name, hero AlbumArtView, centered info
// strip (artist · year · N tracks · total duration), yellow Tracks block,
// list of TrackRow. Current track renders navy-inverted if it's in this
// album.

struct AlbumDetailView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @Environment(\.dismiss) private var dismiss

    let albumID: MPMediaEntityPersistentID

    @State private var album: Album?
    @State private var songs: [Song] = []
    @State private var enrichedFirstSong: Song?
    @State private var totalDuration: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(spacing: 0) {
                    albumTitle
                        .padding(.bottom, 16)

                    heroArt
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)

                    infoStrip
                        .padding(.bottom, 24)

                    ViewTitleBlock("Tracks")
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)

                    trackList
                }
                .padding(.bottom, 24)
            }
            .overflowGradientBars()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: albumID) {
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

    private var albumTitle: some View {
        Text(album?.title ?? "…")
            .font(.nowPlayingTitle)
            .foregroundStyle(Color.ampBlack)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
    }

    // MARK: - Hero art

    private var heroArt: some View {
        AlbumArtView(song: enrichedFirstSong ?? songs.first ?? fallbackSong)
    }

    // AlbumArtView reads song.releaseDate/genre for its back face. All
    // tracks on an album share album/year/genre, so the first song is
    // representative. We prefer the enriched copy (release date read from
    // the file's ID3 tags) to match NowPlayingView — MPMediaItem often
    // leaves releaseDate nil otherwise.
    private var fallbackSong: Song? {
        guard let album else { return nil }
        return Song(
            persistentID: 0,
            title: album.title,
            artist: album.artist,
            album: album.title,
            releaseDate: nil,
            albumTrackNumber: 0
        )
    }

    // MARK: - Info strip

    private var infoStrip: some View {
        VStack(spacing: 4) {
            Text(album?.artist ?? "")
                .font(.custom("AtkinsonHyperlegibleNext-Regular", size: 22))
                .foregroundStyle(Color.ampBlack)
                .underline(album?.artist.isEmpty == false)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let firstID = songs.first?.persistentID else { return }
                    NavigationService.shared.navigateToArtist(forTrack: firstID)
                }
            Text(metaLine)
                .font(.metadata)
                .foregroundStyle(Color.ampMutedText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = yearString { parts.append(year) }
        parts.append("\(songs.count) \(songs.count == 1 ? "track" : "tracks")")
        if totalDuration > 0 { parts.append(formatDuration(totalDuration)) }
        return parts.joined(separator: "  ·  ")
    }

    private var yearString: String? {
        guard let date = enrichedFirstSong?.releaseDate ?? songs.first?.releaseDate else { return nil }
        return String(Calendar.current.component(.year, from: date))
    }

    // MARK: - Track list

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                TrackRow(
                    position: "\(song.albumTrackNumber > 0 ? song.albumTrackNumber : index + 1)",
                    title: song.title,
                    duration: formatDuration(durationFor(song.persistentID)),
                    isCurrent: audioPlayer.currentTrack?.persistentID == song.persistentID,
                    onTap: { playFromIndex(index) }
                )
            }
        }
    }

    // MARK: - Playback
    //
    // All three triggers stay on the Album Detail view — the user asked
    // for the same in-place behaviour as QueueView. Tapping the currently
    // playing row toggles play/pause instead of restarting from the top.

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

    @State private var durations: [MPMediaEntityPersistentID: TimeInterval] = [:]

    private func durationFor(_ id: MPMediaEntityPersistentID) -> TimeInterval {
        durations[id] ?? 0
    }

    private func loadData() async {
        let loaded = await Task.detached(priority: .userInitiated) { () -> (Album?, [Song], [MPMediaEntityPersistentID: TimeInterval], TimeInterval) in
            let songs = LibraryService.shared.getSongs(forAlbum: albumID)
            var map: [MPMediaEntityPersistentID: TimeInterval] = [:]
            var total: TimeInterval = 0
            for song in songs {
                let d = LibraryService.shared.getDuration(forTrack: song.persistentID)
                map[song.persistentID] = d
                total += d
            }
            let album: Album? = songs.first.map {
                Album(id: albumID, title: $0.album, artist: $0.artist)
            }
            return (album, songs, map, total)
        }.value

        self.album = loaded.0
        self.songs = loaded.1
        self.durations = loaded.2
        self.totalDuration = loaded.3

        // Enrich the representative song in a second pass so the backside
        // YEAR + info-strip year fall back to ID3 tags when MPMediaItem
        // doesn't populate releaseDate. The enricher no-ops if it's
        // already set, so this is cheap on well-tagged libraries.
        if let first = loaded.1.first {
            let enriched = await LibraryService.shared.enrichSongWithFileMetadata(first)
            if self.songs.first?.persistentID == enriched.persistentID {
                self.enrichedFirstSong = enriched
            }
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "" }
        let total = Int(t.rounded())
        let minutes = total / 60
        let seconds = total % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mm = minutes % 60
            return String(format: "%d:%02d:%02d", hours, mm, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
