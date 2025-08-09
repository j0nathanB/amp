import Foundation
import MediaPlayer

extension String {
    var searchNormalized: String {
        return self
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)  // Strip diacritics and normalize case
            .replacingOccurrences(of: "'", with: "")  // Remove apostrophes (don't -> dont)
            .replacingOccurrences(of: "'", with: "")  // Remove curly apostrophes
            .replacingOccurrences(of: "&", with: "and") // & -> and
            .replacingOccurrences(of: "?", with: "")  // Remove question marks
            .replacingOccurrences(of: "!", with: "")  // Remove exclamation marks
            .replacingOccurrences(of: "(", with: " ")  // Replace brackets with spaces
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .replacingOccurrences(of: "★", with: "")  // Remove unicode symbols
            .replacingOccurrences(of: "♫", with: "")
            .replacingOccurrences(of: "♥", with: "")
            .replacingOccurrences(of: "→", with: "")
            .components(separatedBy: .whitespacesAndNewlines)  // Split on whitespace
            .filter { !$0.isEmpty }  // Remove empty components
            .joined(separator: " ")  // Rejoin with single spaces
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

class HybridSearchIndex {
    // Word-based index for exact matches (O(1) lookup)
    private var songWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
    private var artistWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
    private var albumWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
    
    // Object caches for fast retrieval
    private var songCache: [MPMediaEntityPersistentID: Song] = [:]
    private var artistCache: [MPMediaEntityPersistentID: Artist] = [:]
    private var albumCache: [MPMediaEntityPersistentID: Album] = [:]
    
    // Fallback data for partial matching
    private var allSongs: [MPMediaItem] = []
    private var allArtists: [MPMediaItemCollection] = []
    private var allAlbums: [MPMediaItemCollection] = []
    
    var isIndexBuilt = false
    
    func buildIndex() async {
        await Task.detached(priority: .userInitiated) {
            // Build song index
            let songsQuery = MPMediaQuery.songs()
            let songs = songsQuery.items ?? []
            self.allSongs = songs
            
            for song in songs {
                guard let title = song.title else { continue }
                
                let normalizedTitle = title.searchNormalized
                let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                
                for word in words {
                    self.songWordIndex[word, default: Set()].insert(song.persistentID)
                }
                
                self.songCache[song.persistentID] = LibraryService.shared.song(from: song)
            }
            
            // Build artist index from songs to ensure we capture all artists
            // MPMediaQuery.artists() sometimes misses artists that exist in songs
            var artistsFromSongs: [MPMediaEntityPersistentID: String] = [:]
            
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
                
                let normalizedName = artistName.searchNormalized
                let words = normalizedName.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                
                #if DEBUG
                if artistName.lowercased().contains("buena vista") {
                    print("🔍 DEBUG: Normalized to '\(normalizedName)', words: \(words)")
                }
                #endif
                
                for word in words {
                    self.artistWordIndex[word, default: Set()].insert(artistID)
                    
                    #if DEBUG
                    if word.hasPrefix("buena") || word.hasPrefix("vista") {
                        print("🔍 DEBUG: Indexed word '\(word)' for artist '\(artistName)'")
                    }
                    #endif
                }
                
                self.artistCache[artistID] = Artist(
                    id: artistID,
                    name: artistName
                )
            }
            
            // Build album index
            let albumsQuery = MPMediaQuery.albums()
            let albums = albumsQuery.collections ?? []
            self.allAlbums = albums
            
            for album in albums {
                guard let representativeItem = album.representativeItem,
                      let albumTitle = representativeItem.albumTitle else { continue }
                
                let normalizedTitle = albumTitle.searchNormalized
                let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                
                for word in words {
                    self.albumWordIndex[word, default: Set()].insert(representativeItem.albumPersistentID)
                }
                
                self.albumCache[representativeItem.albumPersistentID] = Album(
                    id: representativeItem.albumPersistentID,
                    title: albumTitle,
                    artist: representativeItem.artist ?? ""
                )
            }
            
            self.isIndexBuilt = true
            print("🔍 Search index built: \(songs.count) songs, \(artists.count) artists, \(albums.count) albums")
        }.value
    }
    
    func searchSongs(term: String) -> [Song] {
        guard !term.isEmpty else { return [] }
        
        let normalizedTerm = term.searchNormalized
        
        // Get ALL matches - both exact word matches and partial matches
        var allMatches = Set<MPMediaEntityPersistentID>()
        
        // 1. Add exact word matches (O(1))
        if let exactMatches = songWordIndex[normalizedTerm] {
            allMatches.formUnion(exactMatches)
        }
        
        // 2. Add partial word matches
        let partialMatches = getPartialSongMatches(normalizedTerm)
        allMatches.formUnion(partialMatches)
        
        // Convert to songs and sort with priority
        return allMatches.compactMap { songCache[$0] }
            .filter { song in
                let normalizedTitle = song.title.searchNormalized
                let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                
                // Only match if any word starts with the term (word prefix matching)
                let hasMatch = words.contains { $0.hasPrefix(normalizedTerm) }
                
                return hasMatch
            }
            .sorted { song1, song2 in
                let title1 = song1.title.searchNormalized
                let title2 = song2.title.searchNormalized
                let words1 = title1.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                let words2 = title2.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                
                // Prioritize exact word matches over prefix matches
                let hasExactMatch1 = words1.contains { $0 == normalizedTerm }
                let hasExactMatch2 = words2.contains { $0 == normalizedTerm }
                
                if hasExactMatch1 && !hasExactMatch2 { return true }
                if !hasExactMatch1 && hasExactMatch2 { return false }
                
                return song1.title < song2.title
            }
    }
    
    func searchArtists(term: String) -> [Artist] {
        guard !term.isEmpty else { return [] }
        
        let normalizedTerm = term.searchNormalized
        
        #if DEBUG
        if normalizedTerm.contains("sun") || normalizedTerm.contains("ace") || normalizedTerm.contains("bea") {
            print("🔍 DEBUG: Searching for artist term '\(term)' normalized to '\(normalizedTerm)'")
            print("🔍 DEBUG: Exact match in artistWordIndex: \(artistWordIndex[normalizedTerm]?.count ?? 0) results")
            
            // Check what words we have that start with the term (exact and prefix matches)
            let exactWords = artistWordIndex.keys.filter { $0 == normalizedTerm }
            let prefixWords = artistWordIndex.keys.filter { $0.hasPrefix(normalizedTerm) && $0 != normalizedTerm }
            print("🔍 DEBUG: Exact word matches for '\(normalizedTerm)': \(exactWords)")
            print("🔍 DEBUG: Prefix word matches for '\(normalizedTerm)': \(prefixWords)")
        }
        #endif
        
        // Get ALL matches - both exact word matches and partial matches
        var allMatches = Set<MPMediaEntityPersistentID>()
        
        // 1. Add exact word matches (O(1))
        if let exactMatches = artistWordIndex[normalizedTerm] {
            allMatches.formUnion(exactMatches)
            
            #if DEBUG
            if normalizedTerm.contains("sun") || normalizedTerm.contains("ace") || normalizedTerm.contains("bea") {
                let exactResults = exactMatches.compactMap { artistCache[$0] }
                print("🔍 DEBUG: Exact match results: \(exactResults.map { $0.name })")
            }
            #endif
        }
        
        // 2. Add prefix word matches
        let prefixMatches = getPartialArtistMatches(normalizedTerm)
        allMatches.formUnion(prefixMatches)
        
        #if DEBUG
        if normalizedTerm.contains("sun") || normalizedTerm.contains("ace") || normalizedTerm.contains("bea") {
            let prefixResults = prefixMatches.compactMap { artistCache[$0] }
            print("🔍 DEBUG: Prefix match results: \(prefixResults.map { $0.name })")
        }
        #endif
        
        // Convert to artists and sort with priority
        let results = allMatches.compactMap { artistCache[$0] }
            .filter { artist in
                let normalizedName = artist.name.searchNormalized
                let words = normalizedName.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                
                // Only match if any word starts with the term (word prefix matching)
                let hasMatch = words.contains { $0.hasPrefix(normalizedTerm) }
                
                return hasMatch
            }
            .sorted { artist1, artist2 in
                let name1 = artist1.name.searchNormalized
                let name2 = artist2.name.searchNormalized
                let words1 = name1.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                let words2 = name2.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                
                // Prioritize word boundary matches over partial matches
                let hasWordBoundary1 = words1.contains { $0.hasPrefix(normalizedTerm) }
                let hasWordBoundary2 = words2.contains { $0.hasPrefix(normalizedTerm) }
                
                if hasWordBoundary1 && !hasWordBoundary2 { return true }
                if !hasWordBoundary1 && hasWordBoundary2 { return false }
                
                return artist1.name < artist2.name
            }
        
        #if DEBUG
        if normalizedTerm.contains("sun") || normalizedTerm.contains("ace") || normalizedTerm.contains("bea") {
            print("🔍 DEBUG: Final combined results: \(results.map { $0.name })")
        }
        #endif
        
        return results
    }
    
    private func getPartialArtistMatches(_ normalizedTerm: String) -> Set<MPMediaEntityPersistentID> {
        // Get artists from words that START WITH the term (word prefix matches)
        let prefixWords = artistWordIndex.keys.filter { 
            $0.hasPrefix(normalizedTerm) && $0 != normalizedTerm 
        }
        return Set(prefixWords.flatMap { artistWordIndex[$0] ?? [] })
    }
    
    private func getPartialSongMatches(_ normalizedTerm: String) -> Set<MPMediaEntityPersistentID> {
        // Get songs from words that START WITH the term (word prefix matches)
        let prefixWords = songWordIndex.keys.filter { 
            $0.hasPrefix(normalizedTerm) && $0 != normalizedTerm 
        }
        return Set(prefixWords.flatMap { songWordIndex[$0] ?? [] })
    }
    
    func searchAlbums(term: String) -> [Album] {
        guard !term.isEmpty else { return [] }
        
        let normalizedTerm = term.searchNormalized
        
        // Try exact word match first (O(1))
        if let exactMatches = albumWordIndex[normalizedTerm] {
            return exactMatches.compactMap { albumCache[$0] }.sorted { $0.title < $1.title }
        }
        
        // Fall back to partial matching
        return searchAlbumsPartial(normalizedTerm)
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
                    let normalizedTitle = song.title.searchNormalized
                    let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                    
                    // Prefer word boundary matches, but also include partial matches
                    let hasWordBoundaryMatch = words.contains { $0.hasPrefix(normalizedTerm) }
                    let hasPartialMatch = words.contains { $0.contains(normalizedTerm) }
                    
                    return hasWordBoundaryMatch || hasPartialMatch
                }
                .sorted { song1, song2 in
                    let title1 = song1.title.searchNormalized
                    let title2 = song2.title.searchNormalized
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
                
                let normalizedTitle = title.searchNormalized
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
                    let normalizedName = artist.name.searchNormalized
                    let words = normalizedName.components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                    
                    // Prefer word boundary matches, but also include partial matches
                    let hasWordBoundaryMatch = words.contains { $0.hasPrefix(normalizedTerm) }
                    let hasPartialMatch = words.contains { $0.contains(normalizedTerm) }
                    
                    return hasWordBoundaryMatch || hasPartialMatch
                }
                .sorted { artist1, artist2 in
                    let name1 = artist1.name.searchNormalized
                    let name2 = artist2.name.searchNormalized
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
                
                let normalizedName = artistName.searchNormalized
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
                    album.title.searchNormalized.contains(normalizedTerm)
                }
                .sorted { $0.title < $1.title }
        }
        
        // Final fallback: scan all albums (only if index isn't built yet)
        if !isIndexBuilt {
            var seenIDs = Set<MPMediaEntityPersistentID>()
            return allAlbums.compactMap { collection -> Album? in
                guard let representativeItem = collection.representativeItem,
                      let albumTitle = representativeItem.albumTitle,
                      albumTitle.searchNormalized.contains(normalizedTerm) else { return nil }
                
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
        // Start building search index in background
        Task.detached(priority: .background) {
            await self.searchIndex.buildIndex()
        }
    }
    
    private func getNormalizedSearchTerms(for term: String) -> (normalized: String, words: [String]) {
        let normalized = term.searchNormalized
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

            // Parallel search using MPMediaPropertyPredicate for optimal performance
            async let artists = self.searchArtists(term: term)
            async let albums = self.searchAlbums(term: term)  
            async let songs = self.searchSongs(term: term)
            
            return SearchResults(
                artists: await artists,
                albums: await albums,
                songs: await songs
            )
        }.value
    }
    
    // MARK: - Optimized Search Methods
    
    private func searchSongs(term: String) -> [Song] {
        return searchIndex.searchSongs(term: term)
    }
    
    private func searchArtists(term: String) -> [Artist] {
        #if DEBUG
        print("🎤 ARTIST SEARCH: Searching for '\(term)'")
        #endif
        
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
        // For multiple terms, we need to use a different approach since
        // MPMediaPropertyPredicate doesn't handle complex word boundary logic well
        let allSongsQuery = MPMediaQuery.songs()
        let candidateSongs = allSongsQuery.items ?? []
        
        let filteredSongs = candidateSongs.filter { item in
            guard let title = item.title else { return false }
            // All terms must match using word boundary logic
            return terms.allSatisfy { term in
                self.wordBoundaryMatch(searchTerm: term, in: title)
            }
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
            
            // All terms must match using word boundary logic
            let allTermsMatch = terms.allSatisfy { term in
                self.wordBoundaryMatch(searchTerm: term, in: artistName)
            }
            
            return allTermsMatch ? Artist(id: representativeItem.artistPersistentID, name: artistName) : nil
        }
        
        return Array(Set(matchingArtists)).sorted { $0.name < $1.name }
    }
    
    private func searchAlbumsMultipleTerms(terms: [String]) -> [Album] {
        let query = MPMediaQuery.albums()
        let candidateAlbums = query.collections ?? []
        
        let matchingAlbums = candidateAlbums.compactMap { collection -> Album? in
            guard let representativeItem = collection.representativeItem,
                  let albumTitle = representativeItem.albumTitle else { return nil }
            
            // All terms must match using word boundary logic
            let allTermsMatch = terms.allSatisfy { term in
                self.wordBoundaryMatch(searchTerm: term, in: albumTitle)
            }
            
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
        
        // Test cases based on your requirements
        let testCases = [
            // Diacritic tests - your specific examples
            ("cafe", "café tacuba", true, "Should match 'cafe' -> 'café tacuba'"),
            ("cafe", "ojala que llueva cafe", true, "Should match 'cafe' -> 'ojala que llueva cafe'"),
            ("jose", "josé josé", true, "Should match 'jose' -> 'josé josé'"),
            ("café", "cafe tacuba", true, "Should match diacritic insensitive reverse"),
            ("naive", "naïve", true, "Should match diacritic insensitive ï"),
            ("resume", "résumé", true, "Should match diacritic insensitive é"),
            
            // Word boundary tests  
            ("ace", "grace jones", false, "Should NOT match substring in middle of word"),
            ("sun", "king sunny ade", true, "Should match word beginning 'sunny'"),
            ("sun", "sun ra", true, "Should match exact word"),
            ("grace", "grace jones", true, "Should match word beginning"),
            ("jon", "grace jones", true, "Should match word beginning 'jones'"),
            ("rac", "grace jones", false, "Should NOT match middle of word 'grace'"),
            
            // Edge cases
            ("a", "a song", true, "Should match single letter word"),
            ("the", "breathe", false, "Should NOT match 'the' in 'breathe'"),
        ]
        
        for (searchTerm, testText, expectedMatch, description) in testCases {
            let actualMatch = wordBoundaryMatch(searchTerm: searchTerm, in: testText)
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
    
    /// Word-boundary matching with diacritic insensitive search
    /// "cafe" matches "café tacuba" ✅
    /// "ace" does NOT match "grace jones" ❌ 
    /// "sun" matches "king sunny ade" and "sun ra" ✅
    private func wordBoundaryMatch(searchTerm: String, in text: String) -> Bool {
        guard !searchTerm.isEmpty else { return false }
        
        // Use consistent normalization
        let normalizedSearchTerm = searchTerm.searchNormalized
        let searchWords = normalizedSearchTerm.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        // Use consistent normalization for text
        let normalizedText = text.searchNormalized
        
        // All search words must match word boundaries in the text
        return searchWords.allSatisfy { normalizedSearchWord in
            return self.matchesWordBoundaryOptimized(normalizedWord: normalizedSearchWord, in: normalizedText)
        }
    }
    
    private func matchesWordBoundaryOptimized(normalizedWord: String, in normalizedText: String) -> Bool {
        // Use static character set to avoid recreating it on every call
        let textWords = normalizedText.components(separatedBy: LibraryService.wordSeparators)
        
        // Use faster containment check - no need to create intermediate arrays
        for textWord in textWords {
            if !textWord.isEmpty && textWord.hasPrefix(normalizedWord) {
                return true
            }
        }
        return false
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
    
    // Memory-efficient version for large libraries
    func getAllSongIDs() -> [MPMediaEntityPersistentID] {
        guard let items = MPMediaQuery.songs().items else { return [] }
        return items.map { $0.persistentID }
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
