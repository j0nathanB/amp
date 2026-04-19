import Foundation
import MediaPlayer // Added to fix the 'MPMediaEntityPersistentID' error
import UIKit
import SwiftUI

struct Song: Identifiable, Hashable, Codable {
    // The id now refers back to the persistentID from the library
    var id: MPMediaEntityPersistentID { persistentID }

    let persistentID: MPMediaEntityPersistentID
    let title: String
    let artist: String
    let album: String
    let releaseDate: Date?
    let albumTrackNumber: Int
    let discNumber: Int
    let genre: String?

    enum CodingKeys: String, CodingKey {
        case persistentID, title, artist, album, releaseDate, albumTrackNumber, discNumber, genre
    }

    // The initializer is now simpler
    init(persistentID: MPMediaEntityPersistentID, title: String, artist: String, album: String, releaseDate: Date?, albumTrackNumber: Int, discNumber: Int = 1, genre: String? = nil) {
        self.persistentID = persistentID
        self.title = title
        self.artist = artist
        self.album = album
        self.releaseDate = releaseDate
        self.albumTrackNumber = albumTrackNumber
        self.discNumber = discNumber
        self.genre = genre
    }

    // Hash by the persistentID
    func hash(into hasher: inout Hasher) { hasher.combine(persistentID) }
    static func == (lhs: Song, rhs: Song) -> Bool { lhs.persistentID == rhs.persistentID }
}


struct Artist: Identifiable, Hashable, Codable {
    let id: MPMediaEntityPersistentID
    let name: String

    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    static func == (lhs: Artist, rhs: Artist) -> Bool { lhs.name == rhs.name }
}

struct Album: Identifiable, Hashable, Codable {
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

struct Playlist: Identifiable, Codable {
    let id: MPMediaEntityPersistentID
    let name: String
}

// Brutalist tab enum (spec §6). Raw value is the UPPERCASE label shown in the tab bar.
enum AmpTab: String, CaseIterable, Hashable {
    case library = "LIBRARY"
    case search = "SEARCH"
    case queue = "QUEUE"
    case active = "ACTIVE"
}

// PreferenceKey for tracking content height in ScrollViews
struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// PreferenceKey for tracking scroll offset to detect bottom
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
