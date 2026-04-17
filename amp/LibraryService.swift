import Foundation
import MediaPlayer
import AVFoundation

private enum SearchResultComponent {
    case artists([Artist])
    case albums([Album])
    case songs([Song])
}

extension String {
    /// Normalize text for search queries (preserves articles when explicitly typed)
    /// Optimized implementation using native string APIs for performance
    var searchQueryNormalized: String {
        // Safety check for empty or very long strings
        guard !self.isEmpty && self.count < 200 else { return "" }

        // Apply diacritic stripping and case folding using optimized Foundation API
        var normalized = self.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)

        // Apply symbol conversions using optimized string replacement APIs
        // These are batched for better performance than character-by-character iteration
        normalized = normalized
            .replacingOccurrences(of: "$", with: "s")      // Ke$ha -> kesha
            .replacingOccurrences(of: "&", with: " and ")  // Black & Blue -> black and blue
            .replacingOccurrences(of: "+", with: " and ")  // blink+182 -> blink and 182
            .replacingOccurrences(of: "@", with: " at ")   // Deadmau5 @ Play -> deadmau5 at play
            .replacingOccurrences(of: "!", with: "i")      // P!nk -> pink
            .replacingOccurrences(of: "/", with: " ")      // AC/DC -> ac dc
            .replacingOccurrences(of: "-", with: " ")      // Jay-Z -> jay z
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            // Remove punctuation
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ";", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "★", with: "")
            .replacingOccurrences(of: "♫", with: "")
            .replacingOccurrences(of: "♥", with: "")
            .replacingOccurrences(of: "→", with: "")

        // Clean up whitespace and limit words
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

class LibraryService {
    static let shared = LibraryService()

    // Hybrid search index for fast diacritics-insensitive search
    private let searchIndex = HybridSearchIndex()

    // Static character set to improve performance
    private static let wordSeparators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(CharacterSet(charactersIn: "()[]{}"))  // Add more separators

    init() {
        #if !DEBUG
        // Only build real search index in Release builds
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

    // Cache for AVAsset metadata to avoid repeated file reads
    private var metadataCache: [MPMediaEntityPersistentID: Date?] = [:]
    private let metadataCacheQueue = DispatchQueue(label: "com.amp.metadataCache")

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

    /// Enrich a song with metadata from AVAsset (reads ID3 tags directly from file)
    /// Call this on-demand for songs where you need complete metadata (e.g., Now Playing view)
    func enrichSongWithFileMetadata(_ song: Song) async -> Song {
        // If song already has releaseDate, no need to enrich
        guard song.releaseDate == nil else { return song }

        // Get the audio file URL
        guard let assetURL = getAssetURL(for: song) else { return song }

        // Extract metadata from file
        let releaseDate = await Task.detached(priority: .userInitiated) { [weak self] in
            self?.extractReleaseDateFromAsset(url: assetURL, persistentID: song.persistentID)
        }.value

        // Return enriched song
        return Song(
            persistentID: song.persistentID,
            title: song.title,
            artist: song.artist,
            album: song.album,
            releaseDate: releaseDate,
            albumTrackNumber: song.albumTrackNumber,
            discNumber: song.discNumber,
            genre: song.genre
        )
    }

    /// Get asset URL for a song
    private func getAssetURL(for song: Song) -> URL? {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: song.persistentID),
            forProperty: MPMediaItemPropertyPersistentID
        )
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)

        return query.items?.first?.assetURL
    }

    /// Extract release date from AVAsset metadata (reads ID3 tags directly from MP3)
    private func extractReleaseDateFromAsset(url: URL, persistentID: MPMediaEntityPersistentID) -> Date? {
        // Check cache first
        var cachedDate: Date??
        metadataCacheQueue.sync {
            cachedDate = metadataCache[persistentID]
        }

        if let cached = cachedDate {
            return cached // May be nil, which means we already tried and found nothing
        }

        let asset = AVAsset(url: url)
        var extractedDate: Date?

        // Check format-specific metadata (ID3 tags) with proper priority
        // Priority order matches Apple Music behavior:
        // 1. TDRL (Release time - ID3v2.4) - official release date
        // 2. TDOR (Original release time - ID3v2.4) - original release date
        // 3. ©day (iTunes year tag) - usually release date
        // 4. TORY (Original release year - ID3v2.3) - original release year
        // 5. TYER (Year - ID3v2.3) - release year
        // 6. TDRC (Recording time - ID3v2.4) - fallback (may differ from release)
        // 7. Common metadata - last resort
        let priorityTags = ["TDRL", "TDOR", "©day", "TORY", "TYER", "TDRC"]

        // First pass: check priority tags in order
        for priorityTag in priorityTags {
            for format in asset.availableMetadataFormats {
                let metadata = asset.metadata(forFormat: format)

                for item in metadata {
                    guard let key = item.key as? String else { continue }

                    if key == priorityTag {
                        if let value = item.value as? String {
                            extractedDate = parseDateString(value)
                            if extractedDate != nil { break }
                        }
                    }
                }

                if extractedDate != nil { break }
            }

            if extractedDate != nil { break }
        }

        // Second pass: check known date-related metadata keys using strict constants
        if extractedDate == nil {
            let dateKeys = [
                AVMetadataKey.id3MetadataKeyYear,
                AVMetadataKey.id3MetadataKeyRecordingDates,
                AVMetadataKey.id3MetadataKeyDate,
                AVMetadataKey.id3MetadataKeyOriginalReleaseYear,
                AVMetadataKey.quickTimeMetadataKeyCreationDate,
                AVMetadataKey.iTunesMetadataKeyReleaseDate
            ]

            for format in asset.availableMetadataFormats {
                let metadata = asset.metadata(forFormat: format)

                for item in metadata {
                    guard let key = item.key as? String else { continue }

                    // Use strict constant matching instead of fragile string containment
                    if dateKeys.contains(where: { $0.rawValue == key }) {
                        if let value = item.value as? String {
                            extractedDate = parseDateString(value)
                            if extractedDate != nil { break }
                        }
                    }
                }

                if extractedDate != nil { break }
            }
        }

        // Third pass: check common metadata as last resort
        if extractedDate == nil {
            for item in asset.commonMetadata {
                if let key = item.commonKey?.rawValue,
                   (key == AVMetadataKey.commonKeyCreationDate.rawValue ||
                    key == "date"),
                   let value = item.value as? String {
                    extractedDate = parseDateString(value)
                    if extractedDate != nil { break }
                }
            }
        }

        // Cache the result (even if nil, to avoid repeated lookups)
        metadataCacheQueue.sync {
            metadataCache[persistentID] = extractedDate
        }

        return extractedDate
    }

    /// Parse various date string formats from ID3 tags
    /// Defensive parsing with input validation to prevent malformed tag attacks
    private func parseDateString(_ dateString: String) -> Date? {
        // Safety check: reject excessively long input (prevents DoS via malformed tags)
        guard dateString.count <= 100 else {
            print("⚠️ Rejecting overly long date string (\(dateString.count) chars)")
            return nil
        }

        let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Safety check: reject empty strings after trimming
        guard !trimmed.isEmpty else { return nil }

        // Try year-only format first (most common: "2023")
        // Strict bounds checking: 1900-2100 prevents integer overflow attacks
        if let year = Int(trimmed), year >= 1900 && year <= 2100 {
            var components = DateComponents()
            components.year = year
            components.month = 1
            components.day = 1
            return Calendar.current.date(from: components)
        }

        // Try common date formats
        let formatters: [(String, String)] = [
            ("yyyy-MM-dd", "ISO date"),           // 2023-05-15
            ("yyyy/MM/dd", "Slash date"),         // 2023/05/15
            ("yyyy", "Year only"),                 // 2023
            ("dd/MM/yyyy", "European date"),      // 15/05/2023
            ("MM/dd/yyyy", "US date"),            // 05/15/2023
            ("yyyy-MM-dd'T'HH:mm:ss", "ISO datetime"), // 2023-05-15T10:30:00
        ]

        for (format, _) in formatters {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
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
        #if DEBUG
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
        #if DEBUG
        return MockLibraryService.shared.getSong(by: id)
        #else
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)

        guard let item = query.items?.first else { return nil }

        return self.song(from: item)
        #endif
    }

    /// Batch fetch songs by IDs - optimized for queue loading
    /// Returns a dictionary mapping [ID: Song] for O(1) lookups
    func getSongs(by ids: [MPMediaEntityPersistentID]) -> [MPMediaEntityPersistentID: Song] {
        #if DEBUG
        return MockLibraryService.shared.getSongs(by: ids)
        #else
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
        #endif
    }

    func getPlaylists() -> [Playlist] {
        #if DEBUG
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
        #if DEBUG
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
        #if DEBUG
        return MockLibraryService.shared.getTotalSongCount()
        #else
        return MPMediaQuery.songs().items?.count ?? 0
        #endif
    }

    func getSongs(forAlbum albumID: MPMediaEntityPersistentID) -> [Song] {
        #if DEBUG
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
        #if DEBUG
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
        #if DEBUG
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
        #if DEBUG
        return MockLibraryService.shared.getAllSongs()
        #else
        guard let items = MPMediaQuery.songs().items else { return [] }
        return items.map { self.song(from: $0) }
        #endif
    }

    // Memory-efficient version for large libraries
    func getAllSongIDs() -> [MPMediaEntityPersistentID] {
        #if DEBUG
        return MockLibraryService.shared.getAllSongIDs()
        #else
        guard let items = MPMediaQuery.songs().items else { return [] }
        return items.map { $0.persistentID }
        #endif
    }

    func getAllAlbums() -> [Album] {
        #if DEBUG
        return MockLibraryService.shared.getAllAlbums().sorted(by: albumTitleOrder)
        #else
        guard let collections = MPMediaQuery.albums().collections else { return [] }
        let albums = collections.compactMap { collection -> Album? in
            guard let rep = collection.representativeItem,
                  let title = rep.albumTitle else { return nil }
            let artist = rep.albumArtist ?? rep.artist ?? ""
            return Album(id: rep.albumPersistentID, title: title, artist: artist)
        }
        return albums.sorted(by: albumTitleOrder)
        #endif
    }

    // Apple Music-style album sort:
    // 1. Strip leading non-alphanumeric characters when building the sort
    //    key so titles like "#1" compare as "1" and "...And Justice for
    //    All" compares as "And Justice for All".
    // 2. Pure-punctuation titles ( "()" by Sigur Rós, etc.) sort first —
    //    their stripped key is empty, which is always less than any
    //    non-empty key.
    // 3. Remaining titles compare with .numeric so "2" < "4" < "10" rather
    //    than lexicographically. "4" < "4 Way Street" < "5 Minute
    //    Meditations" < "9 to 5" < "10 000 Hz Legend" follows naturally.
    // 4. Tie-break by the original title to keep ordering stable when
    //    stripped keys collide (e.g. "!Hola" and "Hola").
    private func albumTitleOrder(_ a: Album, _ b: Album) -> Bool {
        let keyA = Self.sortKey(for: a.title)
        let keyB = Self.sortKey(for: b.title)

        if keyA.isEmpty != keyB.isEmpty {
            return keyA.isEmpty
        }

        let result = keyA.compare(keyB, options: [.caseInsensitive, .numeric])
        if result == .orderedSame {
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        return result == .orderedAscending
    }

    private static func sortKey(for title: String) -> String {
        String(title.drop(while: { !$0.isLetter && !$0.isNumber }))
    }

    func getAllArtists() -> [Artist] {
        return getAllArtistsWithAlbumCounts().map { $0.artist }
    }

    // Deduplicated artist list with precomputed per-artist album counts.
    // Grouping is by MPMediaItemPropertyAlbumArtistPersistentID so "Radiohead"
    // doesn't appear twice when some tracks carry a featured-artist string in
    // their .artist field — album-artist is the canonical identity.
    func getAllArtistsWithAlbumCounts() -> [(artist: Artist, albumCount: Int)] {
        #if DEBUG
        let artists = MockLibraryService.shared.getAllArtists()
        return artists.map {
            ($0, MockLibraryService.shared.getAlbums(forArtist: $0.id).count)
        }
        #else
        let query = MPMediaQuery()
        query.groupingType = .albumArtist
        guard let collections = query.collections else { return [] }
        // MPMediaQuery occasionally returns multiple collections that resolve
        // to the same persistent ID (e.g. tracks with no albumArtist set all
        // land in separate collections but fall back to the same
        // artistPersistentID). Dedupe by resolved ID after building rows.
        var seen: Set<MPMediaEntityPersistentID> = []
        let rows: [(Artist, Int)] = collections.compactMap { collection in
            guard let rep = collection.representativeItem else { return nil }
            guard let name = rep.albumArtist ?? rep.artist, !name.isEmpty else { return nil }
            let id = rep.albumArtistPersistentID != 0 ? rep.albumArtistPersistentID : rep.artistPersistentID
            guard id != 0 else { return nil }
            guard seen.insert(id).inserted else { return nil }
            let artist = Artist(id: id, name: name)
            let albumCount = Set(collection.items.map { $0.albumPersistentID }).count
            return (artist, albumCount)
        }
        return rows.sorted { $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }
        #endif
    }

    // MARK: - Album-artist canonical lookups
    //
    // Library's new artist rows are grouped by albumArtistPersistentID (see
    // getAllArtistsWithAlbumCounts). These helpers query back using the
    // same predicate so ArtistDetail's albums/songs match the canonical
    // "Radiohead" identity rather than splitting across featured-artist
    // variants. SearchView's legacy flow still uses getAlbums/Songs(forArtist:).

    func getAlbums(forAlbumArtist albumArtistID: MPMediaEntityPersistentID) -> [Album] {
        #if DEBUG
        return MockLibraryService.shared.getAlbums(forArtist: albumArtistID)
        #else
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
        #endif
    }

    func getSongs(forAlbumArtist albumArtistID: MPMediaEntityPersistentID) -> [Song] {
        #if DEBUG
        return MockLibraryService.shared.getSongs(forArtist: albumArtistID)
        #else
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
        #endif
    }

    func getDuration(forTrack id: MPMediaEntityPersistentID) -> TimeInterval {
        #if DEBUG
        return 0
        #else
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        return query.items?.first?.playbackDuration ?? 0
        #endif
    }

    // Reads the MPMediaItem.lyrics property, which maps to the ID3 USLT
    // frame on the file. Returns nil when the track has no embedded lyrics.
    // Phase F is unsynced-only; synced (LRC) parsing lives in a later polish.
    func getLyrics(forTrack id: MPMediaEntityPersistentID) -> String? {
        #if DEBUG
        return nil
        #else
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        return query.items?.first?.lyrics
        #endif
    }

    func getArtworkImage(forAlbum albumID: MPMediaEntityPersistentID, size: CGSize) -> UIImage? {
        #if DEBUG
        return nil
        #else
        let predicate = MPMediaPropertyPredicate(value: albumID, forProperty: MPMediaItemPropertyAlbumPersistentID)
        let query = MPMediaQuery.albums()
        query.addFilterPredicate(predicate)
        guard let rep = query.collections?.first?.representativeItem,
              let artwork = rep.artwork else { return nil }
        return artwork.image(at: size)
        #endif
    }
}

extension LibraryService {
    func getSongIDs(forPlaylist playlistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        #if DEBUG
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
        #if DEBUG
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
        #if DEBUG
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
        #if DEBUG
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
        #if DEBUG
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
