import Foundation
import MediaPlayer
import UIKit

// The library-source seam (Phase 1 of dev/FOLDER_LIBRARY_TOGGLE_PLAN.md).
//
// Everything the app asks a music library for, expressed source-agnostically.
// IDs are MPMediaEntityPersistentID — a UInt64 typealias — so a future
// non-MediaPlayer source can mint deterministic synthetic ids without any
// model changes (see the plan's FNV-1a scheme).
//
// Implementations:
//   - MusicLibrarySource      — MPMediaQuery against the iOS Music library
//   - MockLibrarySource       — DEBUG-only, wraps MockLibraryService
//   - FolderLibrarySource     — (Phase 3) user-picked folder roots
//
// LibraryService owns the active source and forwards data access here. It
// keeps the source-agnostic layers for itself: search index, sort helpers,
// AVAsset metadata enrichment.
protocol LibrarySource {
    func getSong(by id: MPMediaEntityPersistentID) -> Song?
    func getSongs(by ids: [MPMediaEntityPersistentID]) -> [MPMediaEntityPersistentID: Song]

    func getPlaylists() -> [Playlist]
    func getPlaylistDetail(for playlistID: MPMediaEntityPersistentID) -> PlaylistDetail?
    func getSongs(forPlaylist playlistID: MPMediaEntityPersistentID) -> [Song]

    func getTotalSongCount() -> Int
    func getAllSongs() -> [Song]
    func getAllSongIDs() -> [MPMediaEntityPersistentID]
    func getAllAlbums() -> [Album]
    func getAllArtistsWithAlbumCounts() -> [(artist: Artist, albumCount: Int)]

    func getSongs(forAlbum albumID: MPMediaEntityPersistentID) -> [Song]
    func getSongs(forArtist artistID: MPMediaEntityPersistentID) -> [Song]
    func getAlbums(forArtist artistID: MPMediaEntityPersistentID) -> [Album]
    func getAlbums(forAlbumArtist albumArtistID: MPMediaEntityPersistentID) -> [Album]
    func getSongs(forAlbumArtist albumArtistID: MPMediaEntityPersistentID) -> [Song]

    func getDuration(forTrack id: MPMediaEntityPersistentID) -> TimeInterval
    func getLyrics(forTrack id: MPMediaEntityPersistentID) -> String?
    func getArtworkImage(forAlbum albumID: MPMediaEntityPersistentID, size: CGSize) -> UIImage?

    func getSongIDs(forPlaylist playlistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID]
    func getSongIDs(forAlbum albumID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID]
    func getSongIDs(forArtist artistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID]

    func getAllGenres() async -> [String]
    func getGenreDetail(for genre: String) async -> GenreDetail
}

// Everything Genre Detail renders, in display order. Formerly derived
// inside GenreDetailView from its own genre-predicated MPMediaQuery —
// moved behind the seam so folder mode can answer from its catalog.
struct GenreDetail {
    let songs: [Song]
    let albums: [Album]
    let artists: [(artist: Artist, albumCount: Int)]

    static let empty = GenreDetail(songs: [], albums: [], artists: [])
}
