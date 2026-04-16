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
    @State private var totalDuration: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(spacing: 0) {
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
            PlayAllBar(
                title: album?.title ?? "…",
                onTap: playAll,
                onShuffleLongPress: shufflePlayAll
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    // MARK: - Hero art

    private var heroArt: some View {
        AlbumArtView(song: songs.first ?? fallbackSong)
    }

    // AlbumArtView reads song.releaseDate/genre/albumTrackNumber for its
    // back face. Passing the first song is fine for Album Detail since all
    // tracks share album/year/genre.
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
                .font(.custom("AtkinsonHyperlegibleNext-Regular", size: 18))
                .foregroundStyle(Color.ampBlack)
                .lineLimit(1)
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
        guard let date = songs.first?.releaseDate else { return nil }
        return String(Calendar.current.component(.year, from: date))
    }

    // MARK: - Track list

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.persistentID) { index, song in
                TrackRow(
                    position: "\(song.albumTrackNumber > 0 ? song.albumTrackNumber : index + 1)",
                    title: song.title,
                    duration: formatDuration(durationFor(song.persistentID)),
                    isCurrent: audioPlayer.currentTrack?.persistentID == song.persistentID,
                    isPlaying: audioPlayer.isPlaying,
                    audioLevelProvider: audioPlayer.currentTrack?.persistentID == song.persistentID
                        ? { AudioPlayerService.shared.currentAudioLevel }
                        : nil,
                    onTap: { playFromIndex(index) }
                )
            }
        }
    }

    // MARK: - Playback

    private func playAll() {
        let ids = songs.map { $0.persistentID }
        guard !ids.isEmpty else { return }
        audioPlayer.startPlayback(fromTrackIDs: ids, startingAt: 0)
    }

    private func shufflePlayAll() {
        let ids = songs.map { $0.persistentID }.shuffled()
        guard !ids.isEmpty else { return }
        audioPlayer.startPlayback(fromTrackIDs: ids, startingAt: 0)
    }

    private func playFromIndex(_ index: Int) {
        let ids = songs.map { $0.persistentID }
        audioPlayer.startPlayback(fromTrackIDs: ids, startingAt: index)
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
