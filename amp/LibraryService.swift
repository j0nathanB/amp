import Foundation
import MediaPlayer

private enum SearchResultComponent {
    case artists([Artist])
    case albums([Album])
    case songs([Song])
}

extension String {
    /// Normalize text for search queries (preserves articles when explicitly typed)
    var searchQueryNormalized: String {
        // Safety check for empty or very long strings
        guard !self.isEmpty && self.count < 200 else { return "" }
        
        var normalized = self
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            
        // Symbol conversions as per Apple Music spec
        normalized = normalized
            .replacingOccurrences(of: "$", with: "s")     // Ke$ha -> kesha
            .replacingOccurrences(of: "&", with: "and")   // Black & Blue -> black and blue
            .replacingOccurrences(of: "+", with: "and")   // blink+182 -> blink and 182
            .replacingOccurrences(of: "@", with: "at")    // Deadmau5 @ Play -> deadmau5 at play
            .replacingOccurrences(of: "!", with: "i")     // P!nk -> pink (when part of word)
            
        // Convert to spaces
        normalized = normalized
            .replacingOccurrences(of: "/", with: " ")     // AC/DC -> ac dc
            .replacingOccurrences(of: "-", with: " ")     // Jay-Z -> jay z
            
        // Remove punctuation
        normalized = normalized
            .replacingOccurrences(of: ".", with: "")      // R.E.M. -> rem
            .replacingOccurrences(of: "'", with: "")      // Don't -> dont
            .replacingOccurrences(of: "'", with: "")      // Curly apostrophe
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ";", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\"", with: "")
            
        // Handle parentheses - remove them but keep content
        normalized = normalized
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            
        // Remove other unicode symbols
        normalized = normalized
            .replacingOccurrences(of: "★", with: "")
            .replacingOccurrences(of: "♫", with: "")
            .replacingOccurrences(of: "♥", with: "")
            .replacingOccurrences(of: "→", with: "")
            
        // Clean up whitespace but PRESERVE articles in queries
        let components = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .prefix(20) // Limit number of words to prevent issues
            
        return Array(components).joined(separator: " ")
    }
    
    /// Normalize target text for matching (makes articles optional)
    var searchTargetNormalized: String {
        guard !self.isEmpty && self.count < 200 else { return "" }
        
        let normalized = self.searchQueryNormalized
        guard !normalized.isEmpty else { return "" }
        
        let words = normalized.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .prefix(20) // Limit number of words
        
        // Remove leading articles for target text to make them optional
        let articles = ["the", "a", "an", "el", "la", "los", "las", "le", "les", "der", "die", "das"]
        if let firstWord = words.first, articles.contains(firstWord) {
            return Array(words.dropFirst()).joined(separator: " ")
        }
        
        return Array(words).joined(separator: " ")
    }
    
    /// Legacy method for backward compatibility
    var searchNormalized: String {
        return searchQueryNormalized
    }
}

class HybridSearchIndex: @unchecked Sendable {
    // Thread-safe access to indices
    private let indexQueue = DispatchQueue(label: "com.amp.searchIndex", attributes: .concurrent)

    // Word-based index for exact matches (O(1) lookup)
    private var _songWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
    private var _artistWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
    private var _albumWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]

    // Object caches for fast retrieval
    private var _songCache: [MPMediaEntityPersistentID: Song] = [:]
    private var _artistCache: [MPMediaEntityPersistentID: Artist] = [:]
    private var _albumCache: [MPMediaEntityPersistentID: Album] = [:]

    // Fallback data for partial matching
    private var allSongs: [MPMediaItem] = []
    private var allArtists: [MPMediaItemCollection] = []
    private var allAlbums: [MPMediaItemCollection] = []

    private var _isIndexBuilt = false

    var isIndexBuilt: Bool {
        indexQueue.sync { _isIndexBuilt }
    }

    // Thread-safe accessors
    private var songWordIndex: [String: Set<MPMediaEntityPersistentID>] {
        indexQueue.sync { _songWordIndex }
    }

    private var artistWordIndex: [String: Set<MPMediaEntityPersistentID>] {
        indexQueue.sync { _artistWordIndex }
    }

    private var albumWordIndex: [String: Set<MPMediaEntityPersistentID>] {
        indexQueue.sync { _albumWordIndex }
    }

    private var songCache: [MPMediaEntityPersistentID: Song] {
        indexQueue.sync { _songCache }
    }

    private var artistCache: [MPMediaEntityPersistentID: Artist] {
        indexQueue.sync { _artistCache }
    }

    var albumCache: [MPMediaEntityPersistentID: Album] {
        indexQueue.sync { _albumCache }
    }
    
    func buildIndex() async {
        await Task.detached(priority: .userInitiated) {
            // Build temporary indices locally (non-thread-safe during build)
            var tempSongWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
            var tempSongCache: [MPMediaEntityPersistentID: Song] = [:]

            // Build song index
            let songsQuery = MPMediaQuery.songs()
            let songs = songsQuery.items ?? []
            self.allSongs = songs

            for song in songs {
                guard let title = song.title else { continue }

                let normalizedTitle = title.searchTargetNormalized
                let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }

                for word in words {
                    tempSongWordIndex[word, default: Set()].insert(song.persistentID)
                }

                tempSongCache[song.persistentID] = LibraryService.shared.song(from: song)
            }

            // Commit song index atomically
            self.indexQueue.async(flags: .barrier) {
                self._songWordIndex = tempSongWordIndex
                self._songCache = tempSongCache
            }
            
            // Build artist index from songs to ensure we capture all artists
            // MPMediaQuery.artists() sometimes misses artists that exist in songs
            var artistsFromSongs: [MPMediaEntityPersistentID: String] = [:]
            var tempArtistWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
            var tempArtistCache: [MPMediaEntityPersistentID: Artist] = [:]

            for song in songs {
                guard let artistName = song.artist else { continue }
                let artistID = song.artistPersistentID
                artistsFromSongs[artistID] = artistName
            }

            #if DEBUG
            print("🔍 DEBUG: Found \(artistsFromSongs.count) unique artists from songs")
            #endif

            // Also get artists from the traditional query for completeness
            let artistsQuery = MPMediaQuery.artists()
            let artists = artistsQuery.collections ?? []
            self.allArtists = artists

            // Index artists from songs (more comprehensive)
            for (artistID, artistName) in artistsFromSongs {
                #if DEBUG
                if artistName.lowercased().contains("buena vista") {
                    print("🔍 DEBUG: Found artist from songs '\(artistName)' with ID \(artistID)")
                }
                #endif

                let normalizedName = artistName.searchTargetNormalized
                let words = normalizedName.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }

                #if DEBUG
                if artistName.lowercased().contains("buena vista") {
                    print("🔍 DEBUG: Normalized to '\(normalizedName)', words: \(words)")
                }
                #endif

                for word in words {
                    tempArtistWordIndex[word, default: Set()].insert(artistID)

                    #if DEBUG
                    if word.hasPrefix("buena") || word.hasPrefix("vista") {
                        print("🔍 DEBUG: Indexed word '\(word)' for artist '\(artistName)'")
                    }
                    #endif
                }

                tempArtistCache[artistID] = Artist(
                    id: artistID,
                    name: artistName
                )
            }

            // Commit artist index atomically
            self.indexQueue.async(flags: .barrier) {
                self._artistWordIndex = tempArtistWordIndex
                self._artistCache = tempArtistCache
            }
            
            // Build album index
            let albumsQuery = MPMediaQuery.albums()
            let albums = albumsQuery.collections ?? []
            self.allAlbums = albums

            var tempAlbumWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
            var tempAlbumCache: [MPMediaEntityPersistentID: Album] = [:]

            for album in albums {
                guard let representativeItem = album.representativeItem,
                      let albumTitle = representativeItem.albumTitle else { continue }

                let normalizedTitle = albumTitle.searchTargetNormalized
                let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }

                for word in words {
                    tempAlbumWordIndex[word, default: Set()].insert(representativeItem.albumPersistentID)
                }

                tempAlbumCache[representativeItem.albumPersistentID] = Album(
                    id: representativeItem.albumPersistentID,
                    title: albumTitle,
                    artist: representativeItem.artist ?? ""
                )
            }

            // Commit album index and mark as complete atomically
            self.indexQueue.async(flags: .barrier) {
                self._albumWordIndex = tempAlbumWordIndex
                self._albumCache = tempAlbumCache
                self._isIndexBuilt = true
            }

            print("🔍 Search index built: \(songs.count) songs, \(artists.count) artists, \(albums.count) albums")
        }.value
    }
    
    func searchSongs(term: String) -> [Song] {
        guard !term.isEmpty && term.count < 50 else { return [] }
        guard isIndexBuilt else { return [] }

        let normalizedTerm = term.searchQueryNormalized
        guard !normalizedTerm.isEmpty else { return [] }
        
        // Get ALL matches - both exact word matches and partial matches
        var allMatches = Set<MPMediaEntityPersistentID>()
        
        // 1. Add exact word matches (O(1))
        if let exactMatches = songWordIndex[normalizedTerm] {
            allMatches.formUnion(exactMatches)
        }
        
        // 2. Add partial word matches with safety check
        let partialMatches = getPartialSongMatches(normalizedTerm)
        allMatches.formUnion(partialMatches)
        
        // Limit results to prevent memory issues
        if allMatches.count > 1000 {
            allMatches = Set(allMatches.prefix(1000))
        }
        
        // Convert to songs and sort with priority
        return allMatches.compactMap { songCache[$0] }
            .filter { song in
                guard !song.title.isEmpty else { return false }
                
                let normalizedTitle = song.title.searchTargetNormalized
                let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                
                // Only match if any word starts with the term (word prefix matching)
                let hasMatch = words.contains { word in
                    guard !word.isEmpty else { return false }
                    return word.hasPrefix(normalizedTerm)
                }
                
                return hasMatch
            }
            .prefix(500) // Limit final results
            .sorted { song1, song2 in
                let title1 = song1.title.searchTargetNormalized
                let title2 = song2.title.searchTargetNormalized
                
                // 1. Exact title match comes first
                if title1 == normalizedTerm && title2 != normalizedTerm { return true }
                if title1 != normalizedTerm && title2 == normalizedTerm { return false }
                
                // 2. Then alphabetical order
                return song1.title < song2.title
            }
    }
    
    func searchArtists(term: String) -> [Artist] {
        guard !term.isEmpty && term.count < 50 else { return [] }
        guard isIndexBuilt else { return [] }

        let normalizedTerm = term.searchQueryNormalized
        guard !normalizedTerm.isEmpty else { return [] }
        
        // Get ALL matches - both exact word matches and partial matches
        var allMatches = Set<MPMediaEntityPersistentID>()
        
        // 1. Add exact word matches (O(1))
        if let exactMatches = artistWordIndex[normalizedTerm] {
            allMatches.formUnion(exactMatches)
        }
        
        // 2. Add prefix word matches with safety check
        let prefixMatches = getPartialArtistMatches(normalizedTerm)
        allMatches.formUnion(prefixMatches)
        
        // Limit results to prevent memory issues
        if allMatches.count > 500 {
            allMatches = Set(allMatches.prefix(500))
        }
        
        // Convert to artists and sort with priority
        let results = allMatches.compactMap { artistCache[$0] }
            .filter { artist in
                guard !artist.name.isEmpty else { return false }
                
                let normalizedName = artist.name.searchTargetNormalized
                let words = normalizedName.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                
                // Only match if any word starts with the term (word prefix matching)
                let hasMatch = words.contains { word in
                    guard !word.isEmpty else { return false }
                    return word.hasPrefix(normalizedTerm)
                }
                
                return hasMatch
            }
            .prefix(200) // Limit final results
            .sorted { artist1, artist2 in
                let name1 = artist1.name.searchTargetNormalized
                let name2 = artist2.name.searchTargetNormalized
                
                // 1. Exact artist name match comes first
                if name1 == normalizedTerm && name2 != normalizedTerm { return true }
                if name1 != normalizedTerm && name2 == normalizedTerm { return false }
                
                // 2. Then alphabetical order
                return artist1.name < artist2.name
            }
        
        return Array(results)
    }
    
    private func getPartialArtistMatches(_ normalizedTerm: String) -> Set<MPMediaEntityPersistentID> {
        guard !normalizedTerm.isEmpty && normalizedTerm.count < 50 else { return Set() }
        guard isIndexBuilt else { return Set() }

        // Get artists from words that START WITH the term (word prefix matches)
        let prefixWords = artistWordIndex.keys.filter { word in
            guard !word.isEmpty && word != normalizedTerm else { return false }
            return word.hasPrefix(normalizedTerm)
        }
        
        // Limit the number of prefix words to process
        let limitedPrefixWords = Array(prefixWords.prefix(100))
        
        var results = Set<MPMediaEntityPersistentID>()
        for word in limitedPrefixWords {
            if let wordMatches = artistWordIndex[word] {
                results.formUnion(wordMatches)
                // Prevent result set from growing too large
                if results.count > 500 {
                    break
                }
            }
        }
        
        return results
    }
    
    private func getPartialSongMatches(_ normalizedTerm: String) -> Set<MPMediaEntityPersistentID> {
        guard !normalizedTerm.isEmpty && normalizedTerm.count < 50 else { return Set() }
        guard isIndexBuilt else { return Set() }

        // Get songs from words that START WITH the term (word prefix matches)
        let prefixWords = songWordIndex.keys.filter { word in
            guard !word.isEmpty && word != normalizedTerm else { return false }
            return word.hasPrefix(normalizedTerm)
        }
        
        // Limit the number of prefix words to process
        let limitedPrefixWords = Array(prefixWords.prefix(100))
        
        var results = Set<MPMediaEntityPersistentID>()
        for word in limitedPrefixWords {
            if let wordMatches = songWordIndex[word] {
                results.formUnion(wordMatches)
                // Prevent result set from growing too large
                if results.count > 1000 {
                    break
                }
            }
        }
        
        return results
    }
    
    private func getPartialAlbumMatches(_ normalizedTerm: String) -> Set<MPMediaEntityPersistentID> {
        // Get albums from words that START WITH the term (word prefix matches)
        let prefixWords = albumWordIndex.keys.filter { 
            $0.hasPrefix(normalizedTerm) && $0 != normalizedTerm 
        }
        return Set(prefixWords.flatMap { albumWordIndex[$0] ?? [] })
    }
    
    func searchAlbums(term: String) -> [Album] {
        guard !term.isEmpty else { return [] }
        guard isIndexBuilt else { return [] }

        let normalizedTerm = term.searchQueryNormalized
        
        // Get ALL matches - both exact word matches and partial matches (same as songs)
        var allMatches = Set<MPMediaEntityPersistentID>()
        
        // 1. Add exact word matches (O(1))
        if let exactMatches = albumWordIndex[normalizedTerm] {
            allMatches.formUnion(exactMatches)
        }
        
        // 2. Add partial word matches
        let partialMatches = getPartialAlbumMatches(normalizedTerm)
        allMatches.formUnion(partialMatches)
        
        // Convert to albums and sort with priority (same logic as songs)
        return allMatches.compactMap { albumCache[$0] }
            .filter { album in
                let normalizedTitle = album.title.searchTargetNormalized
                let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                
                // Only match if any word starts with the term (word prefix matching)
                let hasMatch = words.contains { $0.hasPrefix(normalizedTerm) }
                
                return hasMatch
            }
            .sorted { album1, album2 in
                let title1 = album1.title.searchTargetNormalized
                let title2 = album2.title.searchTargetNormalized
                let words1 = title1.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                let words2 = title2.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                
                // Prioritize exact word matches over prefix matches
                let hasExactMatch1 = words1.contains { $0 == normalizedTerm }
                let hasExactMatch2 = words2.contains { $0 == normalizedTerm }
                
                if hasExactMatch1 && !hasExactMatch2 { return true }
                if !hasExactMatch1 && hasExactMatch2 { return false }
                
                return album1.title < album2.title
            }
    }
    
    // MARK: - Partial Matching Fallbacks
    
    private func searchSongsPartial(_ normalizedTerm: String) -> [Song] {
        var candidateIDs = Set<MPMediaEntityPersistentID>()
        
        // 1. Get songs from words that start with the term (word boundary matches)
        let prefixWords = songWordIndex.keys.filter { $0.hasPrefix(normalizedTerm) }
        candidateIDs.formUnion(prefixWords.flatMap { songWordIndex[$0] ?? [] })
        
        // 2. Get songs from words that contain the term (partial word matches)
        let containingWords = songWordIndex.keys.filter { $0.contains(normalizedTerm) && !$0.hasPrefix(normalizedTerm) }
        candidateIDs.formUnion(containingWords.flatMap { songWordIndex[$0] ?? [] })
        
        if !candidateIDs.isEmpty {
            return candidateIDs.compactMap { songCache[$0] }
                .filter { song in
                    let normalizedTitle = song.title.searchTargetNormalized
                    let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                    
                    // Prefer word boundary matches, but also include partial matches
                    let hasWordBoundaryMatch = words.contains { $0.hasPrefix(normalizedTerm) }
                    let hasPartialMatch = words.contains { $0.contains(normalizedTerm) }
                    
                    return hasWordBoundaryMatch || hasPartialMatch
                }
                .sorted { song1, song2 in
                    let title1 = song1.title.searchTargetNormalized
                    let title2 = song2.title.searchTargetNormalized
                    let words1 = title1.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    let words2 = title2.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    
                    // Prioritize word boundary matches over partial matches
                    let hasWordBoundary1 = words1.contains { $0.hasPrefix(normalizedTerm) }
                    let hasWordBoundary2 = words2.contains { $0.hasPrefix(normalizedTerm) }
                    
                    if hasWordBoundary1 && !hasWordBoundary2 { return true }
                    if !hasWordBoundary1 && hasWordBoundary2 { return false }
                    
                    return song1.title < song2.title
                }
        }
        
        // Final fallback: scan all songs (only if index isn't built yet)
        if !isIndexBuilt {
            return allSongs.compactMap { song -> Song? in
                guard let title = song.title else { return nil }
                
                let normalizedTitle = title.searchTargetNormalized
                let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                
                // Only match if any word starts with the term (word prefix matching)
                let hasMatch = words.contains { $0.hasPrefix(normalizedTerm) }
                
                guard hasMatch else { return nil }
                
                return LibraryService.shared.song(from: song)
            }.sorted { $0.title < $1.title }
        }
        
        return []
    }
    
    private func searchArtistsPartial(_ normalizedTerm: String) -> [Artist] {
        var candidateIDs = Set<MPMediaEntityPersistentID>()
        
        // 1. Get artists from words that start with the term (word boundary matches)
        let prefixWords = artistWordIndex.keys.filter { $0.hasPrefix(normalizedTerm) }
        candidateIDs.formUnion(prefixWords.flatMap { artistWordIndex[$0] ?? [] })
        
        // 2. Get artists from words that contain the term (partial word matches)
        let containingWords = artistWordIndex.keys.filter { $0.contains(normalizedTerm) && !$0.hasPrefix(normalizedTerm) }
        candidateIDs.formUnion(containingWords.flatMap { artistWordIndex[$0] ?? [] })
        
        if !candidateIDs.isEmpty {
            return candidateIDs.compactMap { artistCache[$0] }
                .filter { artist in
                    let normalizedName = artist.name.searchTargetNormalized
                    let words = normalizedName.components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                    
                    // Prefer word boundary matches, but also include partial matches
                    let hasWordBoundaryMatch = words.contains { $0.hasPrefix(normalizedTerm) }
                    let hasPartialMatch = words.contains { $0.contains(normalizedTerm) }
                    
                    return hasWordBoundaryMatch || hasPartialMatch
                }
                .sorted { artist1, artist2 in
                    let name1 = artist1.name.searchTargetNormalized
                    let name2 = artist2.name.searchTargetNormalized
                    let words1 = name1.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    let words2 = name2.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    
                    // Prioritize exact word matches over prefix matches
                    let hasExactMatch1 = words1.contains { $0 == normalizedTerm }
                    let hasExactMatch2 = words2.contains { $0 == normalizedTerm }
                    
                    if hasExactMatch1 && !hasExactMatch2 { return true }
                    if !hasExactMatch1 && hasExactMatch2 { return false }
                    
                    return artist1.name < artist2.name
                }
        }
        
        // Final fallback: scan all artists (only if index isn't built yet)
        if !isIndexBuilt {
            var seenIDs = Set<MPMediaEntityPersistentID>()
            return allArtists.compactMap { collection -> Artist? in
                guard let representativeItem = collection.representativeItem,
                      let artistName = representativeItem.artist else { return nil }
                
                let normalizedName = artistName.searchTargetNormalized
                let words = normalizedName.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                
                // Only match if any word starts with the term (word prefix matching)
                let hasMatch = words.contains { $0.hasPrefix(normalizedTerm) }
                
                guard hasMatch else { return nil }
                
                let artistID = representativeItem.artistPersistentID
                guard !seenIDs.contains(artistID) else { return nil }
                seenIDs.insert(artistID)
                
                return Artist(id: artistID, name: artistName)
            }.sorted { $0.name < $1.name }
        }
        
        return []
    }
    
    private func searchAlbumsPartial(_ normalizedTerm: String) -> [Album] {
        // Get candidate albums from words that start with the term
        let candidateWords = albumWordIndex.keys.filter { $0.hasPrefix(normalizedTerm) }
        let candidateIDs = Set(candidateWords.flatMap { albumWordIndex[$0] ?? [] })
        
        if !candidateIDs.isEmpty {
            return candidateIDs.compactMap { albumCache[$0] }
                .filter { album in
                    album.title.searchTargetNormalized.contains(normalizedTerm)
                }
                .sorted { $0.title < $1.title }
        }
        
        // Final fallback: scan all albums (only if index isn't built yet)
        if !isIndexBuilt {
            var seenIDs = Set<MPMediaEntityPersistentID>()
            return allAlbums.compactMap { collection -> Album? in
                guard let representativeItem = collection.representativeItem,
                      let albumTitle = representativeItem.albumTitle,
                      albumTitle.searchTargetNormalized.contains(normalizedTerm) else { return nil }
                
                let albumID = representativeItem.albumPersistentID
                guard !seenIDs.contains(albumID) else { return nil }
                seenIDs.insert(albumID)
                
                return Album(
                    id: albumID,
                    title: albumTitle,
                    artist: representativeItem.artist ?? ""
                )
            }.sorted { $0.title < $1.title }
        }
        
        return []
    }
}

class LibraryService {
    static let shared = LibraryService()

    // Hybrid search index for fast diacritics-insensitive search
    private let searchIndex = HybridSearchIndex()

    // Static character set to improve performance
    private static let wordSeparators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(CharacterSet(charactersIn: "()[]{}"))  // Add more separators

    init() {
        #if !targetEnvironment(simulator)
        // Only build real search index on physical device
        Task.detached(priority: .background) {
            await self.searchIndex.buildIndex()
        }
        #endif
    }
    
    private func getNormalizedSearchTerms(for term: String) -> (normalized: String, words: [String]) {
        let normalized = term.searchQueryNormalized
        let words = normalized.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return (normalized: normalized, words: words)
    }

    func song(from item: MPMediaItem) -> Song {
        return Song(
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
        #if targetEnvironment(simulator)
        return await MockLibraryService.shared.search(for: term)
        #else
        // Add safety checks and error handling to prevent crashes
        guard !term.isEmpty && term.count < 100 else {
            return SearchResults(artists: [], albums: [], songs: [])
        }

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else {
                return SearchResults(artists: [], albums: [], songs: [])
            }

            do {
                // Check if this is a multi-word query
                let normalizedTerm = term.searchQueryNormalized
                let searchWords = normalizedTerm.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }

                // Limit search words to prevent performance issues
                guard searchWords.count <= 10 else {
                    return SearchResults(artists: [], albums: [], songs: [])
                }

                if searchWords.count > 1 {
                    // Multi-word search - use the specialized method
                    return await self.searchWithMultipleTerms(terms: searchWords)
                } else {
                    // Single word search - use the optimized index-based search with error handling
                    return await withTaskGroup(of: SearchResultComponent.self) { group in
                        group.addTask {
                            .artists(self.searchArtists(term: term))
                        }
                        group.addTask {
                            .albums(self.searchAlbums(term: term))
                        }
                        group.addTask {
                            .songs(self.searchSongs(term: term))
                        }

                        var artists: [Artist] = []
                        var albums: [Album] = []
                        var songs: [Song] = []

                        for await result in group {
                            switch result {
                            case .artists(let a):
                                artists = a
                            case .albums(let a):
                                albums = a
                            case .songs(let s):
                                songs = s
                            }
                        }

                        return SearchResults(
                            artists: artists,
                            albums: albums,
                            songs: songs
                        )
                    }
                }
            } catch {
                // This catch block is needed for potential future async errors
                print("Search error: \(error.localizedDescription)")
                return SearchResults(artists: [], albums: [], songs: [])
            }
        }.value
        #endif
    }
    
    // MARK: - Optimized Search Methods
    
    private func searchSongs(term: String) -> [Song] {
        return searchIndex.searchSongs(term: term)
    }
    
    private func searchArtists(term: String) -> [Artist] {
        return searchIndex.searchArtists(term: term)
    }
    
    private func searchAlbums(term: String) -> [Album] {
        return searchIndex.searchAlbums(term: term)
    }
    
    // MARK: - Advanced Search Methods
    
    /// Search with multiple terms (all must match)
    func searchWithMultipleTerms(terms: [String]) async -> SearchResults {
        await Task.detached(priority: .userInitiated) {
            guard !terms.isEmpty else { return SearchResults(artists: [], albums: [], songs: []) }
            
            async let artists = self.searchArtistsMultipleTerms(terms: terms)
            async let albums = self.searchAlbumsMultipleTerms(terms: terms)
            async let songs = self.searchSongsMultipleTerms(terms: terms)
            
            return SearchResults(
                artists: await artists,
                albums: await albums,
                songs: await songs
            )
        }.value
    }
    
    private func searchSongsMultipleTerms(terms: [String]) -> [Song] {
        // Use the search index for better performance when available
        if searchIndex.isIndexBuilt {
            return searchSongsMultipleTermsWithIndex(terms: terms)
        } else {
            return searchSongsMultipleTermsFallback(terms: terms)
        }
    }
    
    private func searchSongsMultipleTermsWithIndex(terms: [String]) -> [Song] {
        // Get candidate songs by intersecting results for each term
        var candidateSongIDs: Set<MPMediaEntityPersistentID>?
        
        for term in terms {
            let normalizedTerm = term.searchQueryNormalized
            let termMatches = searchIndex.searchSongs(term: normalizedTerm)
                .map { $0.persistentID }
            let termMatchSet = Set(termMatches)
            
            if candidateSongIDs == nil {
                candidateSongIDs = termMatchSet
            } else {
                // Intersect with previous results (all terms must match)
                candidateSongIDs = candidateSongIDs!.intersection(termMatchSet)
            }
            
            // Early exit if no matches
            if candidateSongIDs?.isEmpty == true {
                break
            }
        }
        
        guard let finalCandidates = candidateSongIDs, !finalCandidates.isEmpty else {
            return []
        }
        
        // Convert back to songs and verify all terms match (additional validation)
        return finalCandidates.compactMap { id in
            guard let song = getSong(by: id) else { return nil }
            
            // Double-check that all terms match in song title only
            let searchString = terms.joined(separator: " ")
            let allTermsMatch = searchMatches(searchTerm: searchString, in: song.title)
            
            return allTermsMatch ? song : nil
        }.sorted { $0.title < $1.title }
    }
    
    private func searchSongsMultipleTermsFallback(terms: [String]) -> [Song] {
        // Fallback method when index isn't built yet
        let allSongsQuery = MPMediaQuery.songs()
        let candidateSongs = allSongsQuery.items ?? []
        
        let filteredSongs = candidateSongs.filter { item in
            guard let title = item.title else { return false }
            
            // All terms must match in song title only
            let searchString = terms.joined(separator: " ")
            return searchMatches(searchTerm: searchString, in: title)
        }
        
        return filteredSongs
            .map { self.song(from: $0) }
            .sorted { $0.title < $1.title }
    }
    
    private func searchArtistsMultipleTerms(terms: [String]) -> [Artist] {
        let query = MPMediaQuery.artists()
        let candidateArtists = query.collections ?? []
        
        let matchingArtists = candidateArtists.compactMap { collection -> Artist? in
            guard let representativeItem = collection.representativeItem,
                  let artistName = representativeItem.artist else { return nil }
            
            // All terms must match in artist name using prefix matching
            let searchString = terms.joined(separator: " ")
            let allTermsMatch = self.searchMatches(searchTerm: searchString, in: artistName)
            
            
            if allTermsMatch {
                return Artist(id: representativeItem.artistPersistentID, name: artistName)
            } else {
                return nil
            }
        }
        
        return Array(Set(matchingArtists)).sorted { $0.name < $1.name }
    }
    
    private func searchAlbumsMultipleTerms(terms: [String]) -> [Album] {
        // Use the search index for better performance when available
        if searchIndex.isIndexBuilt {
            return searchAlbumsMultipleTermsWithIndex(terms: terms)
        } else {
            return searchAlbumsMultipleTermsFallback(terms: terms)
        }
    }
    
    private func searchAlbumsMultipleTermsWithIndex(terms: [String]) -> [Album] {
        // Get candidate albums by intersecting results for each term
        var candidateAlbumIDs: Set<MPMediaEntityPersistentID>?
        
        for term in terms {
            let normalizedTerm = term.searchQueryNormalized
            let termMatches = searchIndex.searchAlbums(term: normalizedTerm)
                .map { $0.id }
            let termMatchSet = Set(termMatches)
            
            if candidateAlbumIDs == nil {
                candidateAlbumIDs = termMatchSet
            } else {
                // Intersect with previous results (all terms must match)
                candidateAlbumIDs = candidateAlbumIDs!.intersection(termMatchSet)
            }
            
            // Early exit if no matches
            if candidateAlbumIDs?.isEmpty == true {
                break
            }
        }
        
        guard let finalCandidates = candidateAlbumIDs, !finalCandidates.isEmpty else {
            return []
        }
        
        // Convert back to albums and verify all terms match (additional validation)
        return finalCandidates.compactMap { id in
            // Get album from cache or query
            if let album = searchIndex.albumCache[id] {
                // Double-check that all terms match using prefix matching
                let searchString = terms.joined(separator: " ")
                let allTermsMatch = searchMatches(searchTerm: searchString, in: album.title)
                
                return allTermsMatch ? album : nil
            }
            return nil
        }.sorted { $0.title < $1.title }
    }
    
    private func searchAlbumsMultipleTermsFallback(terms: [String]) -> [Album] {
        // Fallback method when index isn't built yet
        let query = MPMediaQuery.albums()
        let candidateAlbums = query.collections ?? []
        
        let matchingAlbums = candidateAlbums.compactMap { collection -> Album? in
            guard let representativeItem = collection.representativeItem,
                  let albumTitle = representativeItem.albumTitle else { return nil }
            
            // All terms must match in album title using prefix matching
            let searchString = terms.joined(separator: " ")
            let allTermsMatch = self.searchMatches(searchTerm: searchString, in: albumTitle)
            
            return allTermsMatch ? Album(
                id: representativeItem.albumPersistentID,
                title: albumTitle,
                artist: representativeItem.artist ?? ""
            ) : nil
        }
        
        return Array(Set(matchingAlbums)).sorted { $0.title < $1.title }
    }
    
    // MARK: - Search Utilities
    
    /// Fast genre-based search
    func searchByGenre(_ genre: String) async -> [Song] {
        await Task.detached(priority: .userInitiated) {
            let predicate = MPMediaPropertyPredicate(
                value: genre,
                forProperty: MPMediaItemPropertyGenre,
                comparisonType: .equalTo
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            
            return (query.items ?? [])
                .map { self.song(from: $0) }
                .sorted { $0.title < $1.title }
        }.value
    }
    
    /// Search songs by year range
    func searchByYearRange(from startYear: Int, to endYear: Int) async -> [Song] {
        await Task.detached(priority: .userInitiated) {
            let query = MPMediaQuery.songs()
            
            // Note: Year filtering might need custom logic since MPMediaPropertyPredicate
            // doesn't support range queries directly. For now, get all and filter.
            let allSongs = query.items ?? []
            let filteredSongs = allSongs.filter { item in
                guard let releaseDate = item.releaseDate else { return false }
                let year = Calendar.current.component(.year, from: releaseDate)
                return year >= startYear && year <= endYear
            }
            
            return filteredSongs
                .map { self.song(from: $0) }
                .sorted { $0.title < $1.title }
        }.value
    }
    
    /// Get all available genres in the library (for filter UI)
    func getAllGenres() async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let query = MPMediaQuery.genres()
            return (query.collections ?? []).compactMap { collection in
                collection.representativeItem?.genre
            }.sorted()
        }.value
    }
    
    // MARK: - Performance Testing
    
    /// Legacy search method (for performance comparison)
    func searchLegacy(for term: String) async -> SearchResults {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let result = await Task.detached(priority: .userInitiated) {
            guard !term.isEmpty else { return SearchResults(artists: [], albums: [], songs: []) }

            // Old approach: Fetch all and filter in Swift
            let allArtists = MPMediaQuery.artists().collections ?? []
            let matchingArtists = allArtists.compactMap { collection -> Artist? in
                guard let representativeItem = collection.representativeItem,
                      let artistName = representativeItem.artist,
                      artistName.localizedCaseInsensitiveContains(term) else { return nil }
                return Artist(id: representativeItem.artistPersistentID, name: artistName)
            }

            let allAlbums = MPMediaQuery.albums().collections ?? []
            let matchingAlbums = allAlbums.compactMap { collection -> Album? in
                guard let representativeItem = collection.representativeItem,
                      let albumTitle = representativeItem.albumTitle,
                      albumTitle.localizedCaseInsensitiveContains(term) else { return nil }
                return Album(id: representativeItem.albumPersistentID, title: albumTitle, artist: representativeItem.artist ?? "")
            }

            let allSongs = MPMediaQuery.songs().items ?? []
            let matchingSongs = allSongs.filter { 
                $0.title?.localizedCaseInsensitiveContains(term) == true 
            }

            return SearchResults(
                artists: Array(Set(matchingArtists)).sorted { $0.name < $1.name },
                albums: Array(Set(matchingAlbums)).sorted { $0.title < $1.title },
                songs: matchingSongs.map { self.song(from: $0) }.sorted { $0.title < $1.title }
            )
        }.value
        
        let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("🐌 Legacy search took: \(String(format: "%.3f", timeElapsed))s")
        
        return result
    }
    
    /// Performance comparison between old and new search
    func compareSearchPerformance(term: String) async {
        print("🔍 Comparing search performance for: '\(term)'")
        
        let newStartTime = CFAbsoluteTimeGetCurrent()
        let newResults = await search(for: term)
        let newTimeElapsed = CFAbsoluteTimeGetCurrent() - newStartTime
        
        let oldStartTime = CFAbsoluteTimeGetCurrent()
        let oldResults = await searchLegacy(for: term)
        let oldTimeElapsed = CFAbsoluteTimeGetCurrent() - oldStartTime
        
        print("⚡ New search: \(String(format: "%.3f", newTimeElapsed))s (\(newResults.songs.count) songs)")
        print("🐌 Old search: \(String(format: "%.3f", oldTimeElapsed))s (\(oldResults.songs.count) songs)")
        print("🚀 Performance improvement: \(String(format: "%.1f", oldTimeElapsed / newTimeElapsed))x faster")
    }
    
    /// Test search behavior with specific cases
    func testSearchBehavior() {
        print("🧪 Testing search behavior...")
        
        // Test cases based on Apple Music search behavior
        let testCases = [
            // Diacritic tests
            ("cafe", "café tacuba", true, "Should match 'cafe' -> 'café tacuba'"),
            ("cafe", "ojala que llueva cafe", true, "Should match 'cafe' -> 'ojala que llueva cafe'"),
            ("jose", "josé josé", true, "Should match 'jose' -> 'josé josé'"),
            ("café", "cafe tacuba", true, "Should match diacritic insensitive reverse"),
            ("naive", "naïve", true, "Should match diacritic insensitive ï"),
            ("resume", "résumé", true, "Should match diacritic insensitive é"),
            
            // Prefix matching tests  
            ("ace", "grace jones", false, "Should NOT match substring in middle of word"),
            ("sun", "king sunny ade", true, "Should match word beginning 'sunny'"),
            ("sun", "sun ra", true, "Should match exact word"),
            ("grace", "grace jones", true, "Should match word beginning"),
            ("jon", "grace jones", true, "Should match word beginning 'jones'"),
            ("rac", "grace jones", false, "Should NOT match middle of word 'grace'"),
            
            // Apple Music behavior - no order enforcement
            ("la na", "La Nacional", true, "Should match 'la na' -> 'La Nacional'"),
            ("la na", "Natalia Lafourcade", true, "Should match 'la na' -> 'Natalia Lafourcade' (order doesn't matter)"),
            ("nat la", "Natalia Lafourcade", true, "Should match 'nat la' -> 'Natalia Lafourcade'"),
            
            // Article handling - CRITICAL BUG FIX: Articles only special when they're FIRST word
            ("the a", "The Avalanches", true, "Should match 'the a' -> 'The Avalanches' (starts with 'The A')"),
            ("the a", "The Cannonball Adderley Quartet", false, "Should NOT match 'the a' -> 'The Cannonball Adderley Quartet' ('a' doesn't match)"),
            ("the a", "Rage Against The Machine", false, "Should NOT match 'the a' -> 'Rage Against The Machine' ('the' in middle)"),
            ("the m", "Rage Against The Machine", true, "Should match 'the m' -> 'Rage Against The Machine' ('the' in middle treated as a word)"),
            
            // Article removal
            ("beatles", "The Beatles", true, "Should match 'beatles' -> 'The Beatles' (article removed)"),
            ("beatles", "Beatles", true, "Should match 'beatles' -> 'Beatles'"),
            
            // Edge cases
            ("a", "a song", true, "Should match single letter word"),
            ("the", "breathe", false, "Should NOT match 'the' in 'breathe'"),
        ]
        
        for (searchTerm, testText, expectedMatch, description) in testCases {
            let actualMatch = searchMatches(searchTerm: searchTerm, in: testText)
            let result = actualMatch == expectedMatch ? "✅" : "❌"
            print("\(result) '\(searchTerm)' in '\(testText)': \(actualMatch) - \(description)")
            
            // Show detailed info for failed diacritic tests
            if !result.contains("✅") && (searchTerm.contains("cafe") || testText.contains("café")) {
                let normalizedSearch = searchTerm.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                let normalizedText = testText.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                print("   Normalized: '\(normalizedSearch)' vs '\(normalizedText)'")
            }
        }
        
        print("🧪 Search behavior test complete")
    }
    
    // MARK: - Smart Search Matching
    
    /// Apple Music-style prefix matching with proper article handling
    /// All search tokens must match as prefixes to some word in the text
    /// Order doesn't matter for matching (only for ranking)
    /// Articles are only special when they're the FIRST word of the target
    private func searchMatches(searchTerm: String, in text: String) -> Bool {
        guard !searchTerm.isEmpty else { return false }
        
        let normalizedSearchTerm = searchTerm.searchQueryNormalized
        let searchTokens = normalizedSearchTerm.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        let articles = ["the", "a", "an", "el", "la", "los", "las", "le", "les", "der", "die", "das"]
        
        let normalizedText = text.searchQueryNormalized
        let allTextTokens = normalizedText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        // If first search token is an article, use strict article handling
        let firstTokenIsArticle = searchTokens.first.map { articles.contains($0) } ?? false
        
        if firstTokenIsArticle {
            // When first token is an article, it must match the first word exactly
            // and ALL subsequent tokens must match sequentially (with normal prefix rules)
            let firstSearchToken = searchTokens[0]
            
            // First token must match first word of target
            guard allTextTokens.first == firstSearchToken else {
                return false
            }
            
            // Remaining tokens must match as prefixes IN SEQUENCE (not just anywhere)
            let remainingSearchTokens = Array(searchTokens.dropFirst())
            let remainingTextTokens = Array(allTextTokens.dropFirst())
            
            // Check if we have enough text tokens for sequential matching
            guard remainingSearchTokens.count <= remainingTextTokens.count else {
                return false
            }
            
            // Each search token must match the corresponding text token in sequence
            for (index, searchToken) in remainingSearchTokens.enumerated() {
                let textToken = remainingTextTokens[index]
                if !textToken.hasPrefix(searchToken) {
                    return false
                }
            }
            
            return true
        } else {
            // Normal search - articles in target are optional (can be stripped)
            let textTokensWithoutLeadingArticle = allTextTokens.first.map { articles.contains($0) } ?? false
                ? Array(allTextTokens.dropFirst())
                : allTextTokens
            
            return searchTokens.allSatisfy { searchToken in
                // Try both with and without leading article
                let matchesWithArticles = allTextTokens.contains { $0.hasPrefix(searchToken) }
                let matchesWithoutLeadingArticle = textTokensWithoutLeadingArticle.contains { $0.hasPrefix(searchToken) }
                
                return matchesWithArticles || matchesWithoutLeadingArticle
            }
        }
    }
    
    
    // Keep the old textMatches method for backward compatibility if needed
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
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getSong(by: id)
        #else
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)

        guard let item = query.items?.first else { return nil }

        return self.song(from: item)
        #endif
    }

    func getPlaylists() -> [Playlist] {
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getPlaylists()
        #else
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
        #endif
    }

    func getSongs(forPlaylist playlistID: MPMediaEntityPersistentID) -> [Song] {
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getSongs(forPlaylist: playlistID)
        #else
        let predicate = MPMediaPropertyPredicate(value: playlistID, forProperty: MPMediaPlaylistPropertyPersistentID)
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(predicate)

        guard let songs = query.collections?.first?.items else { return [] }

        return songs.map { self.song(from: $0) }
        #endif
    }

    func getTotalSongCount() -> Int {
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getTotalSongCount()
        #else
        return MPMediaQuery.songs().items?.count ?? 0
        #endif
    }

    func getSongs(forAlbum albumID: MPMediaEntityPersistentID) -> [Song] {
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getSongs(forAlbum: albumID)
        #else
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
        #endif
    }

    func getSongs(forArtist artistID: MPMediaEntityPersistentID) -> [Song] {
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getSongs(forArtist: artistID)
        #else
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
        #endif
    }

    func getAlbums(forArtist artistID: MPMediaEntityPersistentID) -> [Album] {
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getAlbums(forArtist: artistID)
        #else
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
        #endif
    }

    func getAllSongs() -> [Song] {
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getAllSongs()
        #else
        guard let items = MPMediaQuery.songs().items else { return [] }
        return items.map { self.song(from: $0) }
        #endif
    }

    // Memory-efficient version for large libraries
    func getAllSongIDs() -> [MPMediaEntityPersistentID] {
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getAllSongIDs()
        #else
        guard let items = MPMediaQuery.songs().items else { return [] }
        return items.map { $0.persistentID }
        #endif
    }
}

extension LibraryService {
    func getSongIDs(forPlaylist playlistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        #if targetEnvironment(simulator)
        return await MockLibraryService.shared.getSongIDs(forPlaylist: playlistID)
        #else
        await Task.detached(priority: .userInitiated) {
            let predicate = MPMediaPropertyPredicate(value: playlistID, forProperty: MPMediaPlaylistPropertyPersistentID)
            let query = MPMediaQuery.playlists()
            query.addFilterPredicate(predicate)

            guard let songs = query.collections?.first?.items else { return [] }

            // Return just the IDs, not full Song objects
            return songs.map { $0.persistentID }
        }.value
        #endif
    }

    // For search results and other scenarios
    func getSongIDs(forAlbum albumID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        #if targetEnvironment(simulator)
        return await MockLibraryService.shared.getSongIDs(forAlbum: albumID)
        #else
        await Task.detached(priority: .userInitiated) {
            let predicate = MPMediaPropertyPredicate(value: albumID, forProperty: MPMediaItemPropertyAlbumPersistentID)
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)

            guard let songs = query.items else { return [] }

            // Sort by track number for albums
            return songs.sorted { $0.albumTrackNumber < $1.albumTrackNumber }
                       .map { $0.persistentID }
        }.value
        #endif
    }

    func getSongIDs(forArtist artistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        #if targetEnvironment(simulator)
        return await MockLibraryService.shared.getSongIDs(forArtist: artistID)
        #else
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
        #endif
    }
}
extension LibraryService {
    // Get media items instead of Song objects for better performance
    func getMediaItems(forAlbum albumID: MPMediaEntityPersistentID) -> [MPMediaItem] {
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getMediaItems(forAlbum: albumID)
        #else
        let predicate = MPMediaPropertyPredicate(value: albumID, forProperty: MPMediaItemPropertyAlbumPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)

        guard let items = query.items else { return [] }

        // Sort by track number
        return items.sorted { $0.albumTrackNumber < $1.albumTrackNumber }
        #endif
    }

    func getMediaItems(forArtist artistID: MPMediaEntityPersistentID) -> [MPMediaItem] {
        #if targetEnvironment(simulator)
        return MockLibraryService.shared.getMediaItems(forArtist: artistID)
        #else
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
        #endif
    }
}
