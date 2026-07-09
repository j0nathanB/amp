import Foundation
import MediaPlayer
import UIKit

// The folder-roots LibrarySource (Phase 3 of
// dev/FOLDER_LIBRARY_TOGGLE_PLAN.md): reads FolderLibraryService's
// scanned catalog. Phase 3 serves the flat Songs surface — song lookups,
// the all-songs list, durations. Albums/Artists/Genres grouping lands in
// Phase 4 (the catalog already carries albumID/artistID for it) and
// .m3u playlists in Phase 5; those queries return empty until then.
final class FolderLibrarySource: LibrarySource {

    private var catalog: FolderCatalog { FolderLibraryService.shared.catalog }

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

    // Embedded-lyrics read needs an AVAsset open under a security scope;
    // deferred alongside the Phase 4 per-track polish.
    func getLyrics(forTrack id: MPMediaEntityPersistentID) -> String? {
        nil
    }

    // Artwork extraction (AVAsset commonKeyArtwork) is Phase 4, wired
    // through ArtworkCache's per-source dispatch.
    func getArtworkImage(forAlbum albumID: MPMediaEntityPersistentID, size: CGSize) -> UIImage? {
        nil
    }

    // MARK: - Grouping (Phase 4) and playlists (Phase 5) — empty until then

    func getPlaylists() -> [Playlist] {
        []
    }

    func getPlaylistDetail(for playlistID: MPMediaEntityPersistentID) -> PlaylistDetail? {
        nil
    }

    func getSongs(forPlaylist playlistID: MPMediaEntityPersistentID) -> [Song] {
        []
    }

    func getAllAlbums() -> [Album] {
        []
    }

    func getAllArtistsWithAlbumCounts() -> [(artist: Artist, albumCount: Int)] {
        []
    }

    func getSongs(forAlbum albumID: MPMediaEntityPersistentID) -> [Song] {
        []
    }

    func getSongs(forArtist artistID: MPMediaEntityPersistentID) -> [Song] {
        []
    }

    func getAlbums(forArtist artistID: MPMediaEntityPersistentID) -> [Album] {
        []
    }

    func getAlbums(forAlbumArtist albumArtistID: MPMediaEntityPersistentID) -> [Album] {
        []
    }

    func getSongs(forAlbumArtist albumArtistID: MPMediaEntityPersistentID) -> [Song] {
        []
    }

    func getSongIDs(forPlaylist playlistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        []
    }

    func getSongIDs(forAlbum albumID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        []
    }

    func getSongIDs(forArtist artistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        []
    }

    func getAllGenres() async -> [String] {
        []
    }
}
