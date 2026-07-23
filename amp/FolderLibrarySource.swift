import Foundation
import MediaPlayer
import UIKit

// The folder-roots LibrarySource (Phases 3–5 of
// dev/FOLDER_LIBRARY_TOGGLE_PLAN.md): reads FolderLibraryService's
// scanned catalog. Songs, albums/artists/genres grouping (via the
// scan-time albumID/artistID), genre detail, and .m3u/.pls playlists are
// all served from the in-memory catalog — group-on-read over a few
// thousand tracks is microseconds, so no derived grouping caches are
// kept here.
final class FolderLibrarySource: LibrarySource {

    private var catalog: FolderCatalog { FolderLibraryService.shared.catalog }

    // Album-order comparator: disc, then track, then title (untagged
    // files fall back to filename-derived track numbers at scan time).
    private static func albumOrder(_ a: FolderTrack, _ b: FolderTrack) -> Bool {
        if a.song.discNumber != b.song.discNumber {
            return a.song.discNumber < b.song.discNumber
        }
        if a.song.albumTrackNumber != b.song.albumTrackNumber {
            return a.song.albumTrackNumber < b.song.albumTrackNumber
        }
        return LibraryService.nameOrder(a.song.title, b.song.title)
    }

    private func albums(matching predicate: (FolderTrack) -> Bool) -> [Album] {
        var byAlbum: [UInt64: Album] = [:]
        for track in catalog.allTracks where predicate(track) {
            if byAlbum[track.albumID] == nil {
                byAlbum[track.albumID] = Album(
                    id: track.albumID,
                    title: track.song.album,
                    artist: track.albumArtist
                )
            }
        }
        return byAlbum.values.sorted { LibraryService.nameOrder($0.title, $1.title) }
    }

    // MARK: - Songs (live in Phase 3)

    func getSong(by id: MPMediaEntityPersistentID) -> Song? {
        catalog.track(for: id)?.song
    }

    func getSongs(by ids: [MPMediaEntityPersistentID]) -> [MPMediaEntityPersistentID: Song] {
        catalog.songs(for: ids)
    }

    func getTotalSongCount() -> Int {
        catalog.count
    }

    func getAllSongs() -> [Song] {
        catalog.allSongs
    }

    func getAllSongIDs() -> [MPMediaEntityPersistentID] {
        catalog.allSongs.map { $0.persistentID }
    }

    func getDuration(forTrack id: MPMediaEntityPersistentID) -> TimeInterval {
        catalog.track(for: id)?.duration ?? 0
    }

    func getTrackAlbumInfo(forTrack id: MPMediaEntityPersistentID) -> TrackAlbumInfo? {
        guard let track = catalog.track(for: id) else { return nil }
        return TrackAlbumInfo(albumID: track.albumID, artistID: track.artistID, albumArtist: track.albumArtist)
    }

    // Embedded-lyrics read needs an AVAsset opened under a security scope,
    // which wants to be async — this synchronous protocol method stays a
    // stub for folder mode. LyricsView calls FolderLibraryService.lyrics(
    // forTrack:) directly instead, the same bypass ArtworkCache uses for
    // getArtworkImage below.
    func getLyrics(forTrack id: MPMediaEntityPersistentID) -> String? {
        nil
    }

    // Artwork extraction (AVAsset commonKeyArtwork) is Phase 4, wired
    // through ArtworkCache's per-source dispatch.
    func getArtworkImage(forAlbum albumID: MPMediaEntityPersistentID, size: CGSize) -> UIImage? {
        nil
    }

    // MARK: - Albums / artists / genres (grouped from scan-time ids)

    func getAllAlbums() -> [Album] {
        albums { _ in true }
    }

    func getAllArtistsWithAlbumCounts() -> [(artist: Artist, albumCount: Int)] {
        var names: [UInt64: String] = [:]
        var artistAlbums: [UInt64: Set<UInt64>] = [:]
        for track in catalog.allTracks {
            if names[track.artistID] == nil { names[track.artistID] = track.albumArtist }
            artistAlbums[track.artistID, default: []].insert(track.albumID)
        }
        return names.map { (id, name) in
            (Artist(id: id, name: name), artistAlbums[id]?.count ?? 0)
        }
        .sorted { LibraryService.nameOrder($0.0.name, $1.0.name) }
    }

    func getSongs(forAlbum albumID: MPMediaEntityPersistentID) -> [Song] {
        catalog.allTracks
            .filter { $0.albumID == albumID }
            .sorted(by: Self.albumOrder)
            .map { $0.song }
    }

    // Folder mode has one artist identity (album-artist based), so the
    // forArtist / forAlbumArtist pairs answer identically — matching how
    // ArtistDetailView falls back between them.
    func getSongs(forArtist artistID: MPMediaEntityPersistentID) -> [Song] {
        catalog.allTracks
            .filter { $0.artistID == artistID }
            .sorted { a, b in
                if a.song.album != b.song.album { return a.song.album < b.song.album }
                return Self.albumOrder(a, b)
            }
            .map { $0.song }
    }

    func getAlbums(forArtist artistID: MPMediaEntityPersistentID) -> [Album] {
        albums { $0.artistID == artistID }
    }

    func getAlbums(forAlbumArtist albumArtistID: MPMediaEntityPersistentID) -> [Album] {
        albums { $0.artistID == albumArtistID }
    }

    func getSongs(forAlbumArtist albumArtistID: MPMediaEntityPersistentID) -> [Song] {
        getSongs(forArtist: albumArtistID)
    }

    func getSongIDs(forAlbum albumID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        getSongs(forAlbum: albumID).map { $0.persistentID }
    }

    func getSongIDs(forArtist artistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        getSongs(forArtist: artistID).map { $0.persistentID }
    }

    func getAllGenres() async -> [String] {
        var seen: Set<String> = []
        for track in catalog.allTracks {
            // Split compound tags ("Classic Rock/Rock") into deduped
            // components, matching the album card's clickable genres.
            seen.formUnion(track.song.genre?.genreComponents ?? [])
        }
        return seen.sorted()
    }

    func getGenreDetail(for genre: String) async -> GenreDetail {
        // `genre` is a single component; a track matches when that component
        // appears in its (possibly compound) split genre.
        let tracks = catalog.allTracks.filter {
            ($0.song.genre?.genreComponents ?? []).contains(genre)
        }

        var albumMap: [UInt64: Album] = [:]
        var artistMap: [UInt64: Artist] = [:]
        var artistAlbums: [UInt64: Set<UInt64>] = [:]
        for track in tracks {
            if albumMap[track.albumID] == nil {
                albumMap[track.albumID] = Album(id: track.albumID, title: track.song.album, artist: track.albumArtist)
            }
            if artistMap[track.artistID] == nil {
                artistMap[track.artistID] = Artist(id: track.artistID, name: track.albumArtist)
            }
            artistAlbums[track.artistID, default: []].insert(track.albumID)
        }

        return GenreDetail(
            songs: tracks.map { $0.song }.sorted { LibraryService.nameOrder($0.title, $1.title) },
            albums: albumMap.values.sorted { LibraryService.nameOrder($0.title, $1.title) },
            artists: artistMap.values
                .sorted { LibraryService.nameOrder($0.name, $1.name) }
                .map { ($0, artistAlbums[$0.id]?.count ?? 0) }
        )
    }

    // MARK: - Playlists (.m3u/.pls files resolved at scan time — Phase 5)

    // trackIDs were resolved against the same catalog build they're stored
    // with, but a track can still vanish across launches (file deleted,
    // root removed, then a stale catalog decode) — so every read re-checks
    // membership instead of trusting the stored list.

    func getPlaylists() -> [Playlist] {
        catalog.allPlaylists.map { Playlist(id: $0.id, name: $0.name) }
    }

    func getPlaylistDetail(for playlistID: MPMediaEntityPersistentID) -> PlaylistDetail? {
        guard let playlist = catalog.playlist(for: playlistID) else { return nil }
        let tracks = playlist.trackIDs.compactMap { catalog.track(for: $0) }.map {
            PlaylistDetail.Track(song: $0.song, duration: $0.duration, albumID: $0.albumID)
        }
        return PlaylistDetail(name: playlist.name, tracks: tracks)
    }

    func getSongs(forPlaylist playlistID: MPMediaEntityPersistentID) -> [Song] {
        guard let playlist = catalog.playlist(for: playlistID) else { return [] }
        return playlist.trackIDs.compactMap { catalog.track(for: $0)?.song }
    }

    func getSongIDs(forPlaylist playlistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        guard let playlist = catalog.playlist(for: playlistID) else { return [] }
        return playlist.trackIDs.filter { catalog.track(for: $0) != nil }
    }
}
