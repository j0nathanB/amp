//
//  SearchIndexService.swift
//  amp
//
//  Module: Music Library Search Indexing
//  Purpose: Provides optimized hybrid search indexing for fast diacritics-insensitive search
//           across songs, artists, and albums. Implements disk-based caching with automatic
//           invalidation when the music library changes.
//
//  Architecture: Combines O(1) dictionary lookups for exact matches with prefix scanning
//                for partial matches. Extracted from LibraryService for better separation
//                of concerns (Nov 2025 refactoring).
//

import Foundation
import MediaPlayer
import AVFoundation

// MARK: - Codable Index Structure for Persistence
struct PersistedSearchIndex: Codable {
    let songWordIndex: [String: Set<MPMediaEntityPersistentID>]
    let artistWordIndex: [String: Set<MPMediaEntityPersistentID>]
    let albumWordIndex: [String: Set<MPMediaEntityPersistentID>]
    let songCache: [MPMediaEntityPersistentID: CodableSong]
    let artistCache: [MPMediaEntityPersistentID: CodableArtist]
    let albumCache: [MPMediaEntityPersistentID: CodableAlbum]
    // Map from persistent ID to track duration in seconds. Populated from
    // MPMediaItem.playbackDuration during index build so QueueRow doesn't
    // run an MPMediaQuery per visible row just to get a track's length.
    let durationCache: [MPMediaEntityPersistentID: TimeInterval]
    let libraryLastModified: Date
    let version: Int // For future compatibility

    static let currentVersion = 2
}

// Codable versions of data models (lightweight for persistence)
struct CodableSong: Codable, Hashable {
    let persistentID: MPMediaEntityPersistentID
    let title: String
    let artist: String
    let album: String

    init(from song: Song) {
        self.persistentID = song.persistentID
        self.title = song.title
        self.artist = song.artist
        self.album = song.album
    }

    func toSong() -> Song {
        Song(persistentID: persistentID, title: title, artist: artist, album: album,
             releaseDate: nil, albumTrackNumber: 0, discNumber: 0, genre: nil)
    }
}

struct CodableArtist: Codable, Hashable {
    let id: MPMediaEntityPersistentID
    let name: String

    init(from artist: Artist) {
        self.id = artist.id
        self.name = artist.name
    }

    func toArtist() -> Artist {
        Artist(id: id, name: name)
    }
}

struct CodableAlbum: Codable, Hashable {
    let id: MPMediaEntityPersistentID
    let title: String
    let artist: String

    init(from album: Album) {
        self.id = album.id
        self.title = album.title
        self.artist = album.artist
    }

    func toAlbum() -> Album {
        Album(id: id, title: title, artist: artist)
    }
}

class HybridSearchIndex: @unchecked Sendable {
    // Thread-safe access to indices
    private let indexQueue = DispatchQueue(label: "com.amp.searchIndex", attributes: .concurrent)

    // Persistence configuration
    private static let indexCacheURL: URL = {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cacheDir.appendingPathComponent("SearchIndex.cache")
    }()

    // Word-based index for exact matches (O(1) lookup)
    private var _songWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
    private var _artistWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
    private var _albumWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]

    // Object caches for fast retrieval
    private var _songCache: [MPMediaEntityPersistentID: Song] = [:]
    private var _artistCache: [MPMediaEntityPersistentID: Artist] = [:]
    private var _albumCache: [MPMediaEntityPersistentID: Album] = [:]
    private var _durationCache: [MPMediaEntityPersistentID: TimeInterval] = [:]

    // Fallback data for partial matching
    private var allSongs: [MPMediaItem] = []
    private var allArtists: [MPMediaItemCollection] = []
    private var allAlbums: [MPMediaItemCollection] = []

    private var _isIndexBuilt = false

    var isIndexBuilt: Bool {
        indexQueue.sync { _isIndexBuilt }
    }

    // MARK: - Initialization

    init() {
        // Register for library change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(libraryDidChange),
            name: .MPMediaLibraryDidChange,
            object: nil
        )

        // Begin monitoring library changes
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
    }

    deinit {
        MPMediaLibrary.default().endGeneratingLibraryChangeNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func libraryDidChange() {
        print("🔍 Music library changed - invalidating search index cache")

        // Delete cached index file
        try? FileManager.default.removeItem(at: Self.indexCacheURL)

        // Rebuild index asynchronously
        Task.detached(priority: .background) {
            await self.buildIndex()
        }
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

    // O(1) lookup of a cached Song by persistent ID. Used by QueueRow to
    // hydrate visible rows without spawning an MPMediaQuery per track —
    // the on-disk search index is already in memory by the time the
    // queue view appears, so this saves a predicate query per row.
    func song(for id: MPMediaEntityPersistentID) -> Song? {
        indexQueue.sync { _songCache[id] }
    }

    // Cached playback duration (seconds). Same rationale as song(for:).
    func duration(for id: MPMediaEntityPersistentID) -> TimeInterval? {
        indexQueue.sync { _durationCache[id] }
    }

    // MARK: - Index Persistence

    /// Get the last modification date of the music library
    private func getLibraryLastModified() -> Date {
        // Check if library has been modified using MPMediaLibrary's lastModifiedDate
        return MPMediaLibrary.default().lastModifiedDate
    }

    /// Load cached index from disk if available and still valid
    private func loadCachedIndex() -> Bool {
        let fileURL = Self.indexCacheURL

        // Check if cache file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("🔍 No cached search index found")
            return false
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let cached = try decoder.decode(PersistedSearchIndex.self, from: data)

            // Check version compatibility
            guard cached.version == PersistedSearchIndex.currentVersion else {
                print("🔍 Cached index version mismatch (found \(cached.version), expected \(PersistedSearchIndex.currentVersion))")
                return false
            }

            // Check if library has been modified since cache was created
            let currentLibraryDate = getLibraryLastModified()
            guard cached.libraryLastModified >= currentLibraryDate else {
                print("🔍 Library modified since cache (cache: \(cached.libraryLastModified), library: \(currentLibraryDate))")
                return false
            }

            // Cache is valid - load it
            print("🔍 Loading cached search index from disk...")

            indexQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }

                // Load indices
                self._songWordIndex = cached.songWordIndex
                self._artistWordIndex = cached.artistWordIndex
                self._albumWordIndex = cached.albumWordIndex

                // Convert codable models back to full models
                self._songCache = cached.songCache.mapValues { $0.toSong() }
                self._artistCache = cached.artistCache.mapValues { $0.toArtist() }
                self._albumCache = cached.albumCache.mapValues { $0.toAlbum() }
                self._durationCache = cached.durationCache

                self._isIndexBuilt = true

                print("🔍 Search index loaded from cache: \(cached.songCache.count) songs, \(cached.artistCache.count) artists, \(cached.albumCache.count) albums")
            }

            return true
        } catch {
            print("🔍 Error loading cached index: \(error)")
            return false
        }
    }

    /// Save current index to disk for future use
    private func saveCachedIndex() {
        let fileURL = Self.indexCacheURL

        indexQueue.async { [weak self] in
            guard let self = self else { return }

            // Capture current state
            let songWordIndex = self._songWordIndex
            let artistWordIndex = self._artistWordIndex
            let albumWordIndex = self._albumWordIndex
            let songCache = self._songCache
            let artistCache = self._artistCache
            let albumCache = self._albumCache
            let durationCache = self._durationCache

            // Perform encoding and writing off the queue
            Task.detached(priority: .utility) {
                do {
                    // Convert to codable models
                    let codableSongs = songCache.mapValues { CodableSong(from: $0) }
                    let codableArtists = artistCache.mapValues { CodableArtist(from: $0) }
                    let codableAlbums = albumCache.mapValues { CodableAlbum(from: $0) }

                    let persistedIndex = PersistedSearchIndex(
                        songWordIndex: songWordIndex,
                        artistWordIndex: artistWordIndex,
                        albumWordIndex: albumWordIndex,
                        songCache: codableSongs,
                        artistCache: codableArtists,
                        albumCache: codableAlbums,
                        durationCache: durationCache,
                        libraryLastModified: MPMediaLibrary.default().lastModifiedDate,
                        version: PersistedSearchIndex.currentVersion
                    )

                    let encoder = JSONEncoder()
                    let data = try encoder.encode(persistedIndex)
                    try data.write(to: fileURL, options: .atomic)

                    print("🔍 Search index cached to disk (\(data.count / 1024)KB)")
                } catch {
                    print("🔍 Error saving cached index: \(error)")
                }
            }
        }
    }

    // MARK: - Index Building

    func buildIndex() async {
        // Try loading from cache first
        if loadCachedIndex() {
            return // Successfully loaded from cache
        }

        // Cache not available or invalid - build from scratch
        print("🔍 Building search index from scratch...")

        await Task.detached(priority: .userInitiated) {
            // Build temporary indices locally (non-thread-safe during build)
            var tempSongWordIndex: [String: Set<MPMediaEntityPersistentID>] = [:]
            var tempSongCache: [MPMediaEntityPersistentID: Song] = [:]
            var tempDurationCache: [MPMediaEntityPersistentID: TimeInterval] = [:]

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
                tempDurationCache[song.persistentID] = song.playbackDuration
            }

            // Commit song index atomically
            self.indexQueue.async(flags: .barrier) {
                self._songWordIndex = tempSongWordIndex
                self._songCache = tempSongCache
                self._durationCache = tempDurationCache
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

            // Save index to disk for future use
            self.saveCachedIndex()
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

    func searchSongsPartial(_ normalizedTerm: String) -> [Song] {
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

    func searchArtistsPartial(_ normalizedTerm: String) -> [Artist] {
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

    func searchAlbumsPartial(_ normalizedTerm: String) -> [Album] {
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
