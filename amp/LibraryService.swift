import Foundation
import MediaPlayer

class LibraryService {
    static let shared = LibraryService()

    func song(from item: MPMediaItem) -> Song {
        return Song(
            persistentID: item.persistentID,
            title: item.title ?? "Track",
            artist: item.artist ?? "Artist",
            album: item.albumTitle ?? "Album",
            releaseDate: item.releaseDate,
            albumTrackNumber: item.albumTrackNumber
        )
    }

    private func titleContainsWord(startingWith term: String, in text: String?) -> Bool {
        guard let text = text, !term.isEmpty else { return false }
        
        let punctuation = CharacterSet.punctuationCharacters
        let sanitizedText = text.components(separatedBy: punctuation).joined(separator: "")
        let sanitizedSearchTerm = term.components(separatedBy: punctuation).joined(separator: "")
        
        let searchWords = sanitizedSearchTerm.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let titleWords = sanitizedText.components(separatedBy: .whitespacesAndNewlines)

        for searchWord in searchWords {
            var foundMatchForThisWord = false
            for titleWord in titleWords where titleWord.lowercased().hasPrefix(searchWord.lowercased()) {
                foundMatchForThisWord = true
                break
            }
            if !foundMatchForThisWord {
                return false
            }
        }
        return true
    }

    func search(for term: String) async -> SearchResults {
        await Task.detached(priority: .userInitiated) {
            guard !term.isEmpty else { return SearchResults(artists: [], albums: [], songs: []) }

            // --- Step 1: Fetch all artists and filter them in Swift ---
            let allArtists = MPMediaQuery.artists().collections ?? []
            let matchingArtists = allArtists.compactMap { collection -> Artist? in
                guard let representativeItem = collection.representativeItem,
                      let artistName = representativeItem.artist,
                      self.textMatches(searchTerm: term, in: artistName) else { return nil }
                return Artist(id: representativeItem.artistPersistentID, name: artistName)
            }

            // --- Step 2: Fetch all albums and filter them in Swift ---
            let allAlbums = MPMediaQuery.albums().collections ?? []
            let matchingAlbums = allAlbums.compactMap { collection -> Album? in
                guard let representativeItem = collection.representativeItem,
                      let albumTitle = representativeItem.albumTitle,
                      self.textMatches(searchTerm: term, in: albumTitle) else { return nil }
                return Album(id: representativeItem.albumPersistentID, title: albumTitle, artist: representativeItem.artist ?? "")
            }

            // --- Step 3: Fetch all songs and filter them in Swift ---
            let allSongs = MPMediaQuery.songs().items ?? []
            let matchingSongs = allSongs.filter { self.textMatches(searchTerm: term, in: $0.title) }

            // --- Step 4: Return the precise results ---
            return SearchResults(
                artists: Array(Set(matchingArtists)).sorted { $0.name < $1.name },
                albums: Array(Set(matchingAlbums)).sorted { $0.title < $1.title },
                songs: matchingSongs.map { self.song(from: $0) }.sorted { $0.title < $1.title }
            )
        }.value
    }
    
    private func textMatches(searchTerm: String, in text: String?) -> Bool {
        guard let text = text, !searchTerm.isEmpty else { return false }
        
        // 1. Sanitize and split the user's search term into individual words.
        let searchWords = searchTerm.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        // 2. Sanitize and split the text from the library into individual words.
        let punctuation = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        let titleWords = text.components(separatedBy: punctuation).filter { !$0.isEmpty }

        // 3. Check if ALL of the user's search words can be found as a PREFIX in the title words.
        return searchWords.allSatisfy { searchWord in
            titleWords.contains { titleWord in
                // .anchored ensures it only matches the beginning of a word.
                // .caseInsensitive and .diacriticInsensitive make it flexible.
                titleWord.range(of: searchWord, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            }
        }
    }
    
    func getSong(by id: MPMediaEntityPersistentID) -> Song? {
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        
        guard let item = query.items?.first else { return nil }
        
        return self.song(from: item)
    }
    
    func getPlaylists() -> [Playlist] {
            let query = MPMediaQuery.playlists()
            guard let playlists = query.collections else { return [] }
            
            return playlists.compactMap { playlist in
                guard let name = playlist.value(forProperty: MPMediaPlaylistPropertyName) as? String else {
                    return nil
                }
                return Playlist(id: playlist.persistentID, name: name)
            }
        }
    
    func getSongs(forPlaylist playlistID: MPMediaEntityPersistentID) -> [Song] {
            let predicate = MPMediaPropertyPredicate(value: playlistID, forProperty: MPMediaPlaylistPropertyPersistentID)
            let query = MPMediaQuery.playlists()
            query.addFilterPredicate(predicate)
            
            guard let songs = query.collections?.first?.items else { return [] }
            
            return songs.map { self.song(from: $0) }
        }
    
    func getTotalSongCount() -> Int {
        return MPMediaQuery.songs().items?.count ?? 0
    }
    
    func getSongs(forAlbum albumID: MPMediaEntityPersistentID) -> [Song] {
        let predicate = MPMediaPropertyPredicate(value: albumID, forProperty: MPMediaItemPropertyAlbumPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        
        guard let songs = query.items else { return [] }
        
        let mappedSongs = songs.map { self.song(from: $0) }
                
        // Sort by track number for albums
        return mappedSongs.sorted { $0.albumTrackNumber < $1.albumTrackNumber }    }
    
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
    
    func getAllSongs() -> [Song] {
        guard let items = MPMediaQuery.songs().items else { return [] }
        return items.map { self.song(from: $0) }
    }
}

extension LibraryService {
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
    
    // For search results and other scenarios
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
extension LibraryService {
    // Get media items instead of Song objects for better performance
    func getMediaItems(forAlbum albumID: MPMediaEntityPersistentID) -> [MPMediaItem] {
        let predicate = MPMediaPropertyPredicate(value: albumID, forProperty: MPMediaItemPropertyAlbumPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        
        guard let items = query.items else { return [] }
        
        // Sort by track number
        return items.sorted { $0.albumTrackNumber < $1.albumTrackNumber }
    }
    
    func getMediaItems(forArtist artistID: MPMediaEntityPersistentID) -> [MPMediaItem] {
        let predicate = MPMediaPropertyPredicate(value: artistID, forProperty: MPMediaItemPropertyArtistPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        
        guard let items = query.items else { return [] }
        
        // Apply multi-level sort
        return items.sorted { itemA, itemB in
            if let dateA = itemA.releaseDate, let dateB = itemB.releaseDate, dateA != dateB {
                return dateA < dateB
            }
            if itemA.albumTitle != itemB.albumTitle {
                return (itemA.albumTitle ?? "") < (itemB.albumTitle ?? "")
            }
            return itemA.albumTrackNumber < itemB.albumTrackNumber
        }
    }
}
