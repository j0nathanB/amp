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
        // For reliable diacritic support, we need a hybrid approach:
        // 1. If term has no diacritics, use fast MPMediaPropertyPredicate
        // 2. If term has diacritics OR we get few results, fall back to full scan with our logic
        
        let hasNonAscii = term.range(of: "\\P{ASCII}", options: .regularExpression) != nil
        
        if !hasNonAscii {
            // Fast path: Use predicate for ASCII-only terms
            let predicate = MPMediaPropertyPredicate(
                value: term,
                forProperty: MPMediaItemPropertyTitle,
                comparisonType: .contains
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            
            let candidateSongs = query.items ?? []
            let filteredSongs = candidateSongs.filter { item in
                guard let title = item.title else { return false }
                return self.wordBoundaryMatch(searchTerm: term, in: title)
            }
            
            return filteredSongs
                .map { self.song(from: $0) }
                .sorted { $0.title < $1.title }
        } else {
            // Slow path: Full scan for diacritic terms (still reasonably fast)
            let allSongsQuery = MPMediaQuery.songs()
            let allSongs = allSongsQuery.items ?? []
            
            let filteredSongs = allSongs.filter { item in
                guard let title = item.title else { return false }
                return self.wordBoundaryMatch(searchTerm: term, in: title)
            }
            
            return filteredSongs
                .map { self.song(from: $0) }
                .sorted { $0.title < $1.title }
        }
    }
    
    private func searchArtists(term: String) -> [Artist] {
        #if DEBUG
        print("🎤 ARTIST SEARCH: Searching for '\(term)'")
        #endif
        
        let hasNonAscii = term.range(of: "\\P{ASCII}", options: .regularExpression) != nil
        
        if !hasNonAscii {
            // Fast path: Use predicate for ASCII-only terms
            let predicate = MPMediaPropertyPredicate(
                value: term,
                forProperty: MPMediaItemPropertyArtist,
                comparisonType: .contains
            )
            let query = MPMediaQuery.artists()
            query.addFilterPredicate(predicate)
            
            let matchingArtists = (query.collections ?? []).compactMap { collection -> Artist? in
                guard let representativeItem = collection.representativeItem,
                      let artistName = representativeItem.artist,
                      self.wordBoundaryMatch(searchTerm: term, in: artistName) else { return nil }
                return Artist(id: representativeItem.artistPersistentID, name: artistName)
            }
            
            return Array(Set(matchingArtists)).sorted { $0.name < $1.name }
        } else {
            // Slow path: Full scan for diacritic terms
            let allArtistsQuery = MPMediaQuery.artists()
            let allArtists = allArtistsQuery.collections ?? []
            
            let matchingArtists = allArtists.compactMap { collection -> Artist? in
                guard let representativeItem = collection.representativeItem,
                      let artistName = representativeItem.artist,
                      self.wordBoundaryMatch(searchTerm: term, in: artistName) else { return nil }
                return Artist(id: representativeItem.artistPersistentID, name: artistName)
            }
            
            return Array(Set(matchingArtists)).sorted { $0.name < $1.name }
        }
    }
    
    private func searchAlbums(term: String) -> [Album] {
        let hasNonAscii = term.range(of: "\\P{ASCII}", options: .regularExpression) != nil
        
        if !hasNonAscii {
            // Fast path: Use predicate for ASCII-only terms
            let predicate = MPMediaPropertyPredicate(
                value: term,
                forProperty: MPMediaItemPropertyAlbumTitle,
                comparisonType: .contains
            )
            let query = MPMediaQuery.albums()
            query.addFilterPredicate(predicate)
            
            let matchingAlbums = (query.collections ?? []).compactMap { collection -> Album? in
                guard let representativeItem = collection.representativeItem,
                      let albumTitle = representativeItem.albumTitle,
                      self.wordBoundaryMatch(searchTerm: term, in: albumTitle) else { return nil }
                return Album(
                    id: representativeItem.albumPersistentID, 
                    title: albumTitle, 
                    artist: representativeItem.artist ?? ""
                )
            }
            
            return Array(Set(matchingAlbums)).sorted { $0.title < $1.title }
        } else {
            // Slow path: Full scan for diacritic terms
            let allAlbumsQuery = MPMediaQuery.albums()
            let allAlbums = allAlbumsQuery.collections ?? []
            
            let matchingAlbums = allAlbums.compactMap { collection -> Album? in
                guard let representativeItem = collection.representativeItem,
                      let albumTitle = representativeItem.albumTitle,
                      self.wordBoundaryMatch(searchTerm: term, in: albumTitle) else { return nil }
                return Album(
                    id: representativeItem.albumPersistentID,
                    title: albumTitle,
                    artist: representativeItem.artist ?? ""
                )
            }
            
            return Array(Set(matchingAlbums)).sorted { $0.title < $1.title }
        }
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
            // Diacritic tests
            ("cafe", "café tacuba", true, "Should match diacritic insensitive"),
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
        
        // Split search term into individual words
        let searchWords = searchTerm.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        // All search words must match word boundaries in the text
        return searchWords.allSatisfy { searchWord in
            return self.matchesWordBoundary(word: searchWord, in: text)
        }
    }
    
    private func matchesWordBoundary(word: String, in text: String) -> Bool {
        // Normalize both strings for diacritic insensitive comparison
        let normalizedText = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let normalizedWord = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        
        // Split text into words using whitespace and common punctuation
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "()[]{}"))  // Add more separators
        
        let textWords = normalizedText.components(separatedBy: separators)
            .filter { !$0.isEmpty }
        
        // Debug: Print normalized values for troubleshooting (for any diacritic mismatch)
        #if DEBUG
        let hasDiacritics = word != normalizedWord || text != normalizedText
        if hasDiacritics {
            print("🔍 Debug DIACRITIC: '\(word)' -> '\(normalizedWord)' in '\(text)' -> '\(normalizedText)'")
            print("   Words: \(textWords)")
            print("   Checking if any word starts with '\(normalizedWord)'")
            for textWord in textWords {
                let matches = textWord.hasPrefix(normalizedWord)
                print("   '\(textWord)'.hasPrefix('\(normalizedWord)') = \(matches)")
            }
        }
        #endif
        
        // Check if any text word starts with the search word
        let result = textWords.contains { textWord in
            textWord.hasPrefix(normalizedWord)
        }
        
        #if DEBUG
        let hasDiacritics2 = word != normalizedWord || text != normalizedText
        if hasDiacritics2 {
            print("   Final result: \(result)")
        }
        #endif
        
        return result
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
