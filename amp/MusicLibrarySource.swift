import Foundation
import MediaPlayer
import UIKit

// The MediaPlayer-backed LibrarySource: every MPMediaQuery the app runs
// against the iOS Music library, moved verbatim out of LibraryService's
// `#else` (Release) branches in the Phase 1 seam extraction. Behavior is
// intentionally identical — sorting included — so this commit is a pure
// refactor. The index-first shortcuts (search-index cache hits) stayed in
// LibraryService; this class is always the query-of-record.
final class MusicLibrarySource: LibrarySource {

    // Canonical MPMediaItem → Song mapping. Static so LibraryService and
    // SearchIndexService can share the one definition without holding a
    // source reference.
    static func song(from item: MPMediaItem) -> Song {
        Song(
            persistentID: item.persistentID,
            title: item.title ?? "Track",
            artist: item.artist ?? "Artist",
            album: item.albumTitle ?? "Album",
            releaseDate: item.releaseDate,
            albumTrackNumber: item.albumTrackNumber,
            discNumber: item.discNumber,
            genre: item.genre
        )
    }

    private func song(from item: MPMediaItem) -> Song { Self.song(from: item) }

    // MARK: - Single / batch song lookup

    func getSong(by id: MPMediaEntityPersistentID) -> Song? {
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)

        guard let item = query.items?.first else { return nil }

        return self.song(from: item)
    }

    func getSongs(by ids: [MPMediaEntityPersistentID]) -> [MPMediaEntityPersistentID: Song] {
        guard !ids.isEmpty else { return [:] }

        // Create a set for O(1) lookup
        let idSet = Set(ids)

        // Fetch all songs in a single query
        let query = MPMediaQuery.songs()
        guard let allItems = query.items else { return [:] }

        // Build dictionary of songs that match our IDs
        var result: [MPMediaEntityPersistentID: Song] = [:]
        result.reserveCapacity(ids.count)

        for item in allItems {
            let itemID = item.persistentID
            if idSet.contains(itemID) {
                result[itemID] = self.song(from: item)

                // Early exit if we've found all requested songs
                if result.count == ids.count {
                    break
                }
            }
        }

        return result
    }

    // MARK: - Playlists

    func getPlaylists() -> [Playlist] {
        let query = MPMediaQuery.playlists()
        guard let playlists = query.collections else { return [] }

        return playlists.compactMap { collection in
            // For MPMediaPlaylist (which is a subclass of MPMediaItemCollection),
            // we can access the name via value(forProperty:) on the collection itself
            guard let playlist = collection as? MPMediaPlaylist,
                  let name = playlist.value(forProperty: MPMediaPlaylistPropertyName) as? String else {
                return nil
            }
            return Playlist(id: playlist.persistentID, name: name)
        }
    }

    // Everything Playlist Detail needs from ONE predicate-filtered playlist
    // query. See the header comment on LibraryService.getPlaylistDetail for
    // the history of why this is a single query.
    func getPlaylistDetail(for playlistID: MPMediaEntityPersistentID) -> PlaylistDetail? {
        let predicate = MPMediaPropertyPredicate(value: playlistID, forProperty: MPMediaPlaylistPropertyPersistentID)
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(predicate)

        guard let playlist = query.collections?.first as? MPMediaPlaylist else { return nil }
        let name = playlist.value(forProperty: MPMediaPlaylistPropertyName) as? String ?? ""
        let tracks = playlist.items.map { item in
            PlaylistDetail.Track(
                song: self.song(from: item),
                duration: item.playbackDuration,
                albumID: item.albumPersistentID
            )
        }
        return PlaylistDetail(name: name, tracks: tracks)
    }

    func getSongs(forPlaylist playlistID: MPMediaEntityPersistentID) -> [Song] {
        let predicate = MPMediaPropertyPredicate(value: playlistID, forProperty: MPMediaPlaylistPropertyPersistentID)
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(predicate)

        guard let songs = query.collections?.first?.items else { return [] }

        return songs.map { self.song(from: $0) }
    }

    // MARK: - Whole-library

    func getTotalSongCount() -> Int {
        return MPMediaQuery.songs().items?.count ?? 0
    }

    func getAllSongs() -> [Song] {
        guard let items = MPMediaQuery.songs().items else { return [] }
        return items.map { self.song(from: $0) }
    }

    // Memory-efficient version for large libraries
    func getAllSongIDs() -> [MPMediaEntityPersistentID] {
        guard let items = MPMediaQuery.songs().items else { return [] }
        return items.map { $0.persistentID }
    }

    func getAllAlbums() -> [Album] {
        guard let collections = MPMediaQuery.albums().collections else { return [] }
        let albums = collections.compactMap { collection -> Album? in
            guard let rep = collection.representativeItem,
                  let title = rep.albumTitle else { return nil }
            let artist = rep.albumArtist ?? rep.artist ?? ""
            return Album(id: rep.albumPersistentID, title: title, artist: artist)
        }
        return albums.sorted { LibraryService.nameOrder($0.title, $1.title) }
    }

    // Deduplicated artist list with precomputed per-artist album counts.
    // Grouping is by MPMediaItemPropertyAlbumArtistPersistentID so "Radiohead"
    // doesn't appear twice when some tracks carry a featured-artist string in
    // their .artist field — album-artist is the canonical identity.
    func getAllArtistsWithAlbumCounts() -> [(artist: Artist, albumCount: Int)] {
        // Previous impl ran MPMediaQuery(groupingType: .albumArtist) then
        // materialized `collection.items` per artist — N+1 access pattern
        // that cost ~2.4s for 1200 artists on-device (profiled 2026-04-17).
        // One pass over MPMediaQuery.songs().items gives us every artist's
        // canonical ID, name, and distinct album set in a single iteration.
        guard let items = MPMediaQuery.songs().items else { return [] }

        var artistName: [MPMediaEntityPersistentID: String] = [:]
        var artistAlbums: [MPMediaEntityPersistentID: Set<MPMediaEntityPersistentID>] = [:]

        for item in items {
            let id = item.albumArtistPersistentID != 0
                ? item.albumArtistPersistentID
                : item.artistPersistentID
            guard id != 0 else { continue }
            guard let name = item.albumArtist ?? item.artist, !name.isEmpty else { continue }
            if artistName[id] == nil { artistName[id] = name }
            artistAlbums[id, default: []].insert(item.albumPersistentID)
        }

        return artistName.map { (id, name) in
            (Artist(id: id, name: name), artistAlbums[id]?.count ?? 0)
        }
        .sorted { LibraryService.nameOrder($0.0.name, $1.0.name) }
    }

    // MARK: - Album / artist scoped lookups

    func getSongs(forAlbum albumID: MPMediaEntityPersistentID) -> [Song] {
        print("🔍 DEBUG LibraryService: getSongs(forAlbum: \(albumID))")
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: albumID), forProperty: MPMediaItemPropertyAlbumPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)

        guard let songs = query.items else {
            print("🔍 DEBUG LibraryService: query.items is nil")
            return []
        }

        print("🔍 DEBUG LibraryService: Found \(songs.count) songs")
        let mappedSongs = songs.map { self.song(from: $0) }

        // Sort by track number for albums
        return mappedSongs.sorted { $0.albumTrackNumber < $1.albumTrackNumber }
    }

    func getSongs(forArtist artistID: MPMediaEntityPersistentID) -> [Song] {
        let predicate = MPMediaPropertyPredicate(value: artistID, forProperty: MPMediaItemPropertyArtistPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)

        guard let songs = query.items else { return [] }

        let mappedSongs = songs.map { self.song(from: $0) }

        // Apply the multi-level sort
        return mappedSongs.sorted { songA, songB in
            // 1. Sort by Release Date (oldest first)
            if let dateA = songA.releaseDate, let dateB = songB.releaseDate, dateA != dateB {
                return dateA < dateB
            }
            // 2. If dates are same/nil, sort by Album Title
            if songA.album != songB.album {
                return songA.album < songB.album
            }
            // 3. If albums are same, sort by Track Number
            return songA.albumTrackNumber < songB.albumTrackNumber
        }
    }

    func getAlbums(forArtist artistID: MPMediaEntityPersistentID) -> [Album] {
        let predicate = MPMediaPropertyPredicate(value: artistID, forProperty: MPMediaItemPropertyArtistPersistentID)
        let query = MPMediaQuery.albums()
        query.addFilterPredicate(predicate)

        guard let collections = query.collections else { return [] }

        let albums = collections.compactMap { collection -> Album? in
            guard let representativeItem = collection.representativeItem,
                  let albumTitle = representativeItem.albumTitle,
                  let artist = representativeItem.artist else {
                return nil
            }
            let albumID = representativeItem.albumPersistentID
            return Album(id: albumID, title: albumTitle, artist: artist)
        }

        // Sort albums by release date (oldest first), then by title
        return albums.sorted { albumA, albumB in
            // Get representative items for release dates
            let collectionA = collections.first { $0.representativeItem?.albumPersistentID == albumA.id }
            let collectionB = collections.first { $0.representativeItem?.albumPersistentID == albumB.id }

            if let dateA = collectionA?.representativeItem?.releaseDate,
               let dateB = collectionB?.representativeItem?.releaseDate,
               dateA != dateB {
                return dateA < dateB
            }
            return albumA.title < albumB.title
        }
    }

    func getAlbums(forAlbumArtist albumArtistID: MPMediaEntityPersistentID) -> [Album] {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: albumArtistID),
            forProperty: MPMediaItemPropertyAlbumArtistPersistentID
        )
        let query = MPMediaQuery.albums()
        query.addFilterPredicate(predicate)
        guard let collections = query.collections else { return [] }
        let albums = collections.compactMap { collection -> Album? in
            guard let rep = collection.representativeItem,
                  let title = rep.albumTitle else { return nil }
            let artist = rep.albumArtist ?? rep.artist ?? ""
            return Album(id: rep.albumPersistentID, title: title, artist: artist)
        }
        return albums.sorted { a, b in
            let collectionA = collections.first { $0.representativeItem?.albumPersistentID == a.id }
            let collectionB = collections.first { $0.representativeItem?.albumPersistentID == b.id }
            if let dateA = collectionA?.representativeItem?.releaseDate,
               let dateB = collectionB?.representativeItem?.releaseDate,
               dateA != dateB {
                return dateA < dateB
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    func getSongs(forAlbumArtist albumArtistID: MPMediaEntityPersistentID) -> [Song] {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: albumArtistID),
            forProperty: MPMediaItemPropertyAlbumArtistPersistentID
        )
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        guard let items = query.items else { return [] }
        let songs = items.map { self.song(from: $0) }
        return songs.sorted { a, b in
            if let da = a.releaseDate, let db = b.releaseDate, da != db { return da < db }
            if a.album != b.album { return a.album < b.album }
            return a.albumTrackNumber < b.albumTrackNumber
        }
    }

    // MARK: - Per-track properties

    func getDuration(forTrack id: MPMediaEntityPersistentID) -> TimeInterval {
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        return query.items?.first?.playbackDuration ?? 0
    }

    // Reads the MPMediaItem.lyrics property, which maps to the ID3 USLT
    // frame on the file. Returns nil when the track has no embedded lyrics.
    func getLyrics(forTrack id: MPMediaEntityPersistentID) -> String? {
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        return query.items?.first?.lyrics
    }

    func getArtworkImage(forAlbum albumID: MPMediaEntityPersistentID, size: CGSize) -> UIImage? {
        let predicate = MPMediaPropertyPredicate(value: albumID, forProperty: MPMediaItemPropertyAlbumPersistentID)
        let query = MPMediaQuery.albums()
        query.addFilterPredicate(predicate)
        guard let rep = query.collections?.first?.representativeItem,
              let artwork = rep.artwork else { return nil }
        return artwork.image(at: size)
    }

    // MARK: - Async ID lists

    func getSongIDs(forPlaylist playlistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        await Task.detached(priority: .userInitiated) {
            let predicate = MPMediaPropertyPredicate(value: playlistID, forProperty: MPMediaPlaylistPropertyPersistentID)
            let query = MPMediaQuery.playlists()
            query.addFilterPredicate(predicate)

            guard let songs = query.collections?.first?.items else { return [] }

            // Return just the IDs, not full Song objects
            return songs.map { $0.persistentID }
        }.value
    }

    func getSongIDs(forAlbum albumID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        await Task.detached(priority: .userInitiated) {
            let predicate = MPMediaPropertyPredicate(value: albumID, forProperty: MPMediaItemPropertyAlbumPersistentID)
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)

            guard let songs = query.items else { return [] }

            // Sort by track number for albums
            return songs.sorted { $0.albumTrackNumber < $1.albumTrackNumber }
                       .map { $0.persistentID }
        }.value
    }

    func getSongIDs(forArtist artistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        await Task.detached(priority: .userInitiated) {
            let predicate = MPMediaPropertyPredicate(value: artistID, forProperty: MPMediaItemPropertyArtistPersistentID)
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)

            guard let songs = query.items else { return [] }

            // Apply the multi-level sort
            return songs.sorted { songA, songB in
                // 1. Sort by Release Date (oldest first)
                if let dateA = songA.releaseDate, let dateB = songB.releaseDate, dateA != dateB {
                    return dateA < dateB
                }
                // 2. If dates are same/nil, sort by Album Title
                if songA.albumTitle != songB.albumTitle {
                    return songA.albumTitle ?? "" < songB.albumTitle ?? ""
                }
                // 3. If albums are same, sort by Track Number
                return songA.albumTrackNumber < songB.albumTrackNumber
            }.map { $0.persistentID }
        }.value
    }
}
