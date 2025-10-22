import Foundation
import MediaPlayer // Added to fix the 'MPMediaEntityPersistentID' error
import UIKit

struct Song: Identifiable, Hashable, Codable {
    // The id now refers back to the persistentID from the library
    var id: MPMediaEntityPersistentID { persistentID }

    let persistentID: MPMediaEntityPersistentID
    let title: String
    let artist: String
    let album: String
    let releaseDate: Date?
    let albumTrackNumber: Int
    let genre: String?

    enum CodingKeys: String, CodingKey {
        case persistentID, title, artist, album, releaseDate, albumTrackNumber, genre
    }

    // The initializer is now simpler
    init(persistentID: MPMediaEntityPersistentID, title: String, artist: String, album: String, releaseDate: Date?, albumTrackNumber: Int, genre: String? = nil) {
        self.persistentID = persistentID
        self.title = title
        self.artist = artist
        self.album = album
        self.releaseDate = releaseDate
        self.albumTrackNumber = albumTrackNumber
        self.genre = genre
    }

    // Hash by the persistentID
    func hash(into hasher: inout Hasher) { hasher.combine(persistentID) }
    static func == (lhs: Song, rhs: Song) -> Bool { lhs.persistentID == rhs.persistentID }
}


struct Artist: Identifiable, Hashable {
    let id: MPMediaEntityPersistentID
    let name: String

    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    static func == (lhs: Artist, rhs: Artist) -> Bool { lhs.name == rhs.name }
}

struct Album: Identifiable, Hashable {
    let id: MPMediaEntityPersistentID
    let title: String
    let artist: String

    func hash(into hasher: inout Hasher) { hasher.combine(title) }
    static func == (lhs: Album, rhs: Album) -> Bool { lhs.title == rhs.title }
}

struct SearchResults {
    var artists: [Artist]
    var albums: [Album]
    var songs: [Song]
}

struct Playlist: Identifiable {
    let id: MPMediaEntityPersistentID
    let name: String
}

enum Tab {
    case playlists, queue, search, nowPlaying
}

// Optimized Song struct that doesn't create UUID for every instance

struct SongOptimized: Identifiable, Hashable, Codable {
    // Use persistentID as the identifier
    var id: MPMediaEntityPersistentID { persistentID }
    
    let persistentID: MPMediaEntityPersistentID
    let title: String
    let artist: String
    let album: String
    let releaseDate: Date?
    let albumTrackNumber: Int
    
    // Hash by persistentID
    func hash(into hasher: inout Hasher) {
        hasher.combine(persistentID)
    }
    
    static func == (lhs: SongOptimized, rhs: SongOptimized) -> Bool {
        lhs.persistentID == rhs.persistentID
    }
}

// Extension to LibraryService for optimized song creation
extension LibraryService {
    func songOptimized(from item: MPMediaItem) -> Song {
        // If you must use UUID, at least make it lazy
        return Song(
            persistentID: item.persistentID,
            title: item.title ?? "Track",
            artist: item.artist ?? "Artist",
            album: item.albumTitle ?? "Album",
            releaseDate: item.releaseDate,
            albumTrackNumber: item.albumTrackNumber
        )
    }
    
    // Async method to get all songs
    func getAllSongsAsync() async -> [Song] {
        await Task.detached(priority: .userInitiated) {
            let query = MPMediaQuery.songs()
            guard let items = query.items else { return [] }
            
            // Process in chunks
            let chunkSize = 100
            var allSongs: [Song] = []
            allSongs.reserveCapacity(items.count)
            
            for i in stride(from: 0, to: items.count, by: chunkSize) {
                let end = min(i + chunkSize, items.count)
                let chunk = items[i..<end]
                
                let chunkSongs = chunk.map { self.song(from: $0) }
                allSongs.append(contentsOf: chunkSongs)
            }
            
            return allSongs
        }.value
    }
}
struct LightweightSong: Identifiable, Hashable {
    // We use the persistentID as the id for this simple struct
    var id: MPMediaEntityPersistentID { persistentID }
    let persistentID: MPMediaEntityPersistentID
}
