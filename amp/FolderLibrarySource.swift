import Foundation
import MediaPlayer
import UIKit

// The folder-roots LibrarySource. Phase 2 stub: folder mode exists
// end-to-end (Settings toggle, switch sequence, empty library) with this
// returning empty results everywhere. Phase 3 replaces the bodies with
// reads from the folder-scan cache (see dev/FOLDER_LIBRARY_TOGGLE_PLAN.md:
// FolderRootStore + FolderScanService + FolderLibraryCache), minting
// deterministic FNV-1a ids for tracks/albums/artists.
final class FolderLibrarySource: LibrarySource {

    func getSong(by id: MPMediaEntityPersistentID) -> Song? {
        nil
    }

    func getSongs(by ids: [MPMediaEntityPersistentID]) -> [MPMediaEntityPersistentID: Song] {
        [:]
    }

    func getPlaylists() -> [Playlist] {
        []
    }

    func getPlaylistDetail(for playlistID: MPMediaEntityPersistentID) -> PlaylistDetail? {
        nil
    }

    func getSongs(forPlaylist playlistID: MPMediaEntityPersistentID) -> [Song] {
        []
    }

    func getTotalSongCount() -> Int {
        0
    }

    func getAllSongs() -> [Song] {
        []
    }

    func getAllSongIDs() -> [MPMediaEntityPersistentID] {
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

    func getDuration(forTrack id: MPMediaEntityPersistentID) -> TimeInterval {
        0
    }

    func getLyrics(forTrack id: MPMediaEntityPersistentID) -> String? {
        nil
    }

    func getArtworkImage(forAlbum albumID: MPMediaEntityPersistentID, size: CGSize) -> UIImage? {
        nil
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
