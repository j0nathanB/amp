import SwiftUI
import MediaPlayer

// Spec §7.8: mirrors AlbumDetail with key differences:
// - art area renders a 2×2 collage of the first four unique album covers
//   from the playlist's tracks (§7.8)
// - track rows show the artist on each row (playlists are multi-artist)
// - no "Tracks" yellow block (the track count sits in the meta line)
//
// Chrome uses a compact "Play all" bar right-aligned next to BackButton;
// the playlist name sits above the collage, same format as Album /
// Artist / Genre Detail.
//
// Phase H ships the collage from track album artwork. If the playlist
// itself has iTunes-assigned artwork we could prefer that; hooking in
// MPMediaPlaylist.representativeItem.artwork is a small follow-up.

struct PlaylistDetailView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @Environment(\.dismiss) private var dismiss

    let playlistID: MPMediaEntityPersistentID

    @State private var name: String = ""
    @State private var songs: [Song] = []
    @State private var durations: [MPMediaEntityPersistentID: TimeInterval] = [:]
    @State private var totalDuration: TimeInterval = 0
    @State private var collageArt: [UIImage?] = [nil, nil, nil, nil]

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ScrollView {
                VStack(spacing: 0) {
                    playlistTitle
                        .padding(.bottom, 16)

                    collage
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)

                    infoStrip
                        .padding(.bottom, 24)

                    trackList
                }
                .padding(.bottom, 24)
            }
            .overflowGradientBars()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: playlistID) {
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

    private var playlistTitle: some View {
        Text(name.isEmpty ? "…" : name)
            .font(.nowPlayingTitle)
            .foregroundStyle(Color.ampBlack)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
    }

    // MARK: - Collage (§7.8)

    private var collage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                collageCell(0)
                Rectangle().fill(Color.ampBlack).frame(width: 2)
                collageCell(1)
            }
            Rectangle().fill(Color.ampBlack).frame(height: 2)
            HStack(spacing: 0) {
                collageCell(2)
                Rectangle().fill(Color.ampBlack).frame(width: 2)
                collageCell(3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .brutalistStroke()
    }

    @ViewBuilder
    private func collageCell(_ index: Int) -> some View {
        if let image = collageArt[index] {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipped()
        } else {
            Rectangle().fill(Color.ampNavy)
        }
    }

    // MARK: - Info strip

    private var infoStrip: some View {
        Text(metaLine)
            .font(.metadata)
            .foregroundStyle(Color.ampMutedText)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
    }

    private var metaLine: String {
        var parts: [String] = ["\(songs.count) \(songs.count == 1 ? "track" : "tracks")"]
        if totalDuration > 0 { parts.append(formatDuration(totalDuration)) }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Track list — per spec §7.8 each row carries the artist line

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                TrackRow(
                    position: "\(index + 1)",
                    title: song.title,
                    artist: song.artist,
                    duration: formatDuration(durations[song.persistentID] ?? 0),
                    isCurrent: audioPlayer.currentTrack?.persistentID == song.persistentID,
                    onTap: { playFromIndex(index) }
                )
            }
        }
    }

    // MARK: - Playback

    // All three triggers stay on the Playlist Detail view. Tapping the
    // currently playing row toggles play/pause — same convention as the
    // Queue tab and Album Detail.

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
        let pid = playlistID
        let loaded = await Task.detached(priority: .userInitiated) { () -> (String, [Song], [MPMediaEntityPersistentID: TimeInterval], TimeInterval, [MPMediaEntityPersistentID]) in
            let name = LibraryService.shared.getPlaylists().first { $0.id == pid }?.name ?? ""
            let songs = LibraryService.shared.getSongs(forPlaylist: pid)

            var durations: [MPMediaEntityPersistentID: TimeInterval] = [:]
            var total: TimeInterval = 0
            for song in songs {
                let d = LibraryService.shared.getDuration(forTrack: song.persistentID)
                durations[song.persistentID] = d
                total += d
            }

            // First four unique album IDs from the track list (preserving order).
            var seenAlbums: Set<String> = []
            var uniqueAlbumKeys: [String] = []
            for song in songs {
                let key = "\(song.artist)::\(song.album)"
                if seenAlbums.insert(key).inserted {
                    uniqueAlbumKeys.append(key)
                    if uniqueAlbumKeys.count == 4 { break }
                }
            }
            // We need MPMediaEntityPersistentIDs to fetch artwork; look up
            // via album title on representative tracks.
            let albumIDs: [MPMediaEntityPersistentID] = uniqueAlbumKeys.compactMap { key in
                songs.first { "\($0.artist)::\($0.album)" == key }?.persistentID
            }
            return (name, songs, durations, total, albumIDs)
        }.value

        self.name = loaded.0
        self.songs = loaded.1
        self.durations = loaded.2
        self.totalDuration = loaded.3

        await loadCollageArt(fromRepresentativeTrackIDs: loaded.4)
    }

    // For each representative track ID we resolve the album persistent ID
    // via a tiny MPMediaQuery, then pull its artwork. Done off the main
    // thread so scroll stays smooth even with four art loads.
    private func loadCollageArt(fromRepresentativeTrackIDs trackIDs: [MPMediaEntityPersistentID]) async {
        let art = await Task.detached(priority: .userInitiated) { () -> [UIImage?] in
            var result: [UIImage?] = [nil, nil, nil, nil]
            for (i, trackID) in trackIDs.prefix(4).enumerated() {
                let albumID = albumPersistentID(forTrack: trackID)
                if let albumID {
                    result[i] = LibraryService.shared.getArtworkImage(
                        forAlbum: albumID,
                        size: CGSize(width: 400, height: 400)
                    )
                }
            }
            // Repeat covers to fill if fewer than 4 unique albums, per spec §7.8.
            let available = result.compactMap { $0 }
            if !available.isEmpty {
                for i in 0..<4 where result[i] == nil {
                    result[i] = available[i % available.count]
                }
            }
            return result
        }.value
        self.collageArt = art
    }
}

// Helper that lives outside the type because we need it inside a
// Task.detached closure without capturing self.
private func albumPersistentID(forTrack trackID: MPMediaEntityPersistentID) -> MPMediaEntityPersistentID? {
    #if DEBUG
    return nil
    #else
    let predicate = MPMediaPropertyPredicate(
        value: NSNumber(value: trackID),
        forProperty: MPMediaItemPropertyPersistentID
    )
    let query = MPMediaQuery.songs()
    query.addFilterPredicate(predicate)
    return query.items?.first?.albumPersistentID
    #endif
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
