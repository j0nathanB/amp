import Foundation
import MediaPlayer

#if targetEnvironment(simulator)

/// Mock library service for simulator testing
/// Provides realistic fake music data without requiring actual MPMediaLibrary access
class MockLibraryService {
    static let shared = MockLibraryService()

    // Mock data storage
    private var mockSongs: [Song] = []
    private var mockArtists: [Artist] = []
    private var mockAlbums: [Album] = []
    private var mockPlaylists: [Playlist] = []

    // Search index (simplified version of the real one)
    private var songIndex: [String: [Song]] = [:]
    private var artistIndex: [String: [Artist]] = [:]
    private var albumIndex: [String: [Album]] = [:]

    private init() {
        generateMockData()
        buildSearchIndex()
    }

    // MARK: - Mock Data Generation

    private func generateMockData() {
        // Generate mock artists
        let artistData: [(id: Int, name: String)] = [
            (1, "The Beatles"),
            (2, "Deftones"),
            (3, "Café Tacuba"),
            (4, "José José"),
            (5, "Radiohead"),
            (6, "Pink Floyd"),
            (7, "Spice Girls"),
            (8, "Buena Vista Social Club"),
            (9, "Björk"),
            (10, "Sigur Rós"),
            (11, "My Chemical Romance"),
            (12, "The National"),
            (13, "Arcade Fire"),
            (14, "Def Leppard"),
            (15, "Grace Jones"),
            (16, "Miles Davis"),
            (17, "John Coltrane"),
            (18, "Natalia Lafourcade"),
            (19, "R.E.M."),
            (20, "AC/DC"),
        ]

        mockArtists = artistData.map { Artist(id: MPMediaEntityPersistentID($0.id), name: $0.name) }

        // Generate mock albums with realistic data
        let albumData: [(id: Int, title: String, artistId: Int)] = [
            (101, "Abbey Road", 1),
            (102, "White Pony", 2),
            (103, "Ré", 3),
            (104, "Secretos", 4),
            (105, "OK Computer", 5),
            (106, "The Dark Side of the Moon", 6),
            (107, "Spice", 7),
            (108, "Buena Vista Social Club", 8),
            (109, "Homogenic", 9),
            (110, "( )", 10),
            (111, "The Black Parade", 11),
            (112, "High Violet", 12),
            (113, "Funeral", 13),
            (114, "Hysteria", 14),
            (115, "Nightclubbing", 15),
            (116, "Kind of Blue", 16),
            (117, "A Love Supreme", 17),
            (118, "Hasta la Raíz", 18),
            (119, "Automatic for the People", 19),
            (120, "Back in Black", 20),
        ]

        mockAlbums = albumData.map { album in
            let artist = mockArtists.first { $0.id == MPMediaEntityPersistentID(album.artistId) }
            return Album(
                id: MPMediaEntityPersistentID(album.id),
                title: album.title,
                artist: artist?.name ?? "Unknown"
            )
        }

        // Generate mock songs
        var songId = 1000
        var allSongs: [Song] = []

        // The Beatles - Abbey Road
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Come Together", artist: "The Beatles", album: "Abbey Road", trackNumber: 1, genre: "Rock"),
            createSong(id: songId + 1, title: "Something", artist: "The Beatles", album: "Abbey Road", trackNumber: 2, genre: "Rock"),
            createSong(id: songId + 2, title: "Here Comes the Sun", artist: "The Beatles", album: "Abbey Road", trackNumber: 7, genre: "Rock"),
        ])
        songId += 3

        // Deftones - White Pony
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Feiticeira", artist: "Deftones", album: "White Pony", trackNumber: 1, genre: "Alternative Metal"),
            createSong(id: songId + 1, title: "Digital Bath", artist: "Deftones", album: "White Pony", trackNumber: 2, genre: "Alternative Metal"),
            createSong(id: songId + 2, title: "Change (In the House of Flies)", artist: "Deftones", album: "White Pony", trackNumber: 5, genre: "Alternative Metal"),
        ])
        songId += 3

        // Café Tacuba - Ré
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "El Ciclón", artist: "Café Tacuba", album: "Ré", trackNumber: 1, genre: "Latin Rock"),
            createSong(id: songId + 1, title: "La Ingrata", artist: "Café Tacuba", album: "Ré", trackNumber: 2, genre: "Latin Rock"),
            createSong(id: songId + 2, title: "Las Flores", artist: "Café Tacuba", album: "Ré", trackNumber: 6, genre: "Latin Rock"),
        ])
        songId += 3

        // José José - Secretos
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Lo Pasado, Pasado", artist: "José José", album: "Secretos", trackNumber: 1, genre: "Latin Pop"),
            createSong(id: songId + 1, title: "Secretos", artist: "José José", album: "Secretos", trackNumber: 2, genre: "Latin Pop"),
        ])
        songId += 2

        // Radiohead - OK Computer
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Airbag", artist: "Radiohead", album: "OK Computer", trackNumber: 1, genre: "Alternative Rock"),
            createSong(id: songId + 1, title: "Paranoid Android", artist: "Radiohead", album: "OK Computer", trackNumber: 2, genre: "Alternative Rock"),
            createSong(id: songId + 2, title: "Karma Police", artist: "Radiohead", album: "OK Computer", trackNumber: 6, genre: "Alternative Rock"),
            createSong(id: songId + 3, title: "No Surprises", artist: "Radiohead", album: "OK Computer", trackNumber: 8, genre: "Alternative Rock"),
        ])
        songId += 4

        // Pink Floyd - The Dark Side of the Moon
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Speak to Me", artist: "Pink Floyd", album: "The Dark Side of the Moon", trackNumber: 1, genre: "Progressive Rock"),
            createSong(id: songId + 1, title: "Breathe", artist: "Pink Floyd", album: "The Dark Side of the Moon", trackNumber: 2, genre: "Progressive Rock"),
            createSong(id: songId + 2, title: "Time", artist: "Pink Floyd", album: "The Dark Side of the Moon", trackNumber: 4, genre: "Progressive Rock"),
            createSong(id: songId + 3, title: "Money", artist: "Pink Floyd", album: "The Dark Side of the Moon", trackNumber: 6, genre: "Progressive Rock"),
        ])
        songId += 4

        // Spice Girls - Spice
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Wannabe", artist: "Spice Girls", album: "Spice", trackNumber: 1, genre: "Pop"),
            createSong(id: songId + 1, title: "Say You'll Be There", artist: "Spice Girls", album: "Spice", trackNumber: 2, genre: "Pop"),
            createSong(id: songId + 2, title: "2 Become 1", artist: "Spice Girls", album: "Spice", trackNumber: 3, genre: "Pop"),
        ])
        songId += 3

        // Buena Vista Social Club
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Chan Chan", artist: "Buena Vista Social Club", album: "Buena Vista Social Club", trackNumber: 1, genre: "Cuban"),
            createSong(id: songId + 1, title: "De Camino a la Vereda", artist: "Buena Vista Social Club", album: "Buena Vista Social Club", trackNumber: 2, genre: "Cuban"),
        ])
        songId += 2

        // Björk - Homogenic
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Hunter", artist: "Björk", album: "Homogenic", trackNumber: 1, genre: "Electronic"),
            createSong(id: songId + 1, title: "Jóga", artist: "Björk", album: "Homogenic", trackNumber: 2, genre: "Electronic"),
            createSong(id: songId + 2, title: "Bachelorette", artist: "Björk", album: "Homogenic", trackNumber: 4, genre: "Electronic"),
        ])
        songId += 3

        // My Chemical Romance - The Black Parade
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Welcome to the Black Parade", artist: "My Chemical Romance", album: "The Black Parade", trackNumber: 5, genre: "Alternative Rock"),
            createSong(id: songId + 1, title: "Famous Last Words", artist: "My Chemical Romance", album: "The Black Parade", trackNumber: 13, genre: "Alternative Rock"),
        ])
        songId += 2

        // Def Leppard - Hysteria
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Pour Some Sugar on Me", artist: "Def Leppard", album: "Hysteria", trackNumber: 4, genre: "Rock"),
            createSong(id: songId + 1, title: "Love Bites", artist: "Def Leppard", album: "Hysteria", trackNumber: 7, genre: "Rock"),
        ])
        songId += 2

        // Grace Jones - Nightclubbing
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Walking in the Rain", artist: "Grace Jones", album: "Nightclubbing", trackNumber: 1, genre: "New Wave"),
            createSong(id: songId + 1, title: "Pull Up to the Bumper", artist: "Grace Jones", album: "Nightclubbing", trackNumber: 2, genre: "New Wave"),
        ])
        songId += 2

        // Natalia Lafourcade - Hasta la Raíz
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Hasta la Raíz", artist: "Natalia Lafourcade", album: "Hasta la Raíz", trackNumber: 1, genre: "Latin Pop"),
            createSong(id: songId + 1, title: "Nunca Es Suficiente", artist: "Natalia Lafourcade", album: "Hasta la Raíz", trackNumber: 2, genre: "Latin Pop"),
        ])
        songId += 2

        // R.E.M. - Automatic for the People
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Drive", artist: "R.E.M.", album: "Automatic for the People", trackNumber: 1, genre: "Alternative Rock"),
            createSong(id: songId + 1, title: "Man on the Moon", artist: "R.E.M.", album: "Automatic for the People", trackNumber: 4, genre: "Alternative Rock"),
            createSong(id: songId + 2, title: "Everybody Hurts", artist: "R.E.M.", album: "Automatic for the People", trackNumber: 7, genre: "Alternative Rock"),
        ])
        songId += 3

        // AC/DC - Back in Black
        allSongs.append(contentsOf: [
            createSong(id: songId, title: "Hells Bells", artist: "AC/DC", album: "Back in Black", trackNumber: 1, genre: "Hard Rock"),
            createSong(id: songId + 1, title: "Back in Black", artist: "AC/DC", album: "Back in Black", trackNumber: 4, genre: "Hard Rock"),
            createSong(id: songId + 2, title: "You Shook Me All Night Long", artist: "AC/DC", album: "Back in Black", trackNumber: 5, genre: "Hard Rock"),
        ])

        mockSongs = allSongs

        // Generate mock playlists
        mockPlaylists = [
            Playlist(id: 5000, name: "Favorites"),
            Playlist(id: 5001, name: "Rock Classics"),
            Playlist(id: 5002, name: "Latin Vibes"),
            Playlist(id: 5003, name: "Workout Mix"),
        ]
    }

    private func createSong(id: Int, title: String, artist: String, album: String, trackNumber: Int, genre: String) -> Song {
        Song(
            persistentID: MPMediaEntityPersistentID(id),
            title: title,
            artist: artist,
            album: album,
            releaseDate: Date(timeIntervalSince1970: TimeInterval(arc4random_uniform(1000000000))),
            albumTrackNumber: trackNumber,
            genre: genre
        )
    }

    // MARK: - Search Index

    private func buildSearchIndex() {
        // Build song index
        for song in mockSongs {
            let normalizedTitle = song.title.searchQueryNormalized
            let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }

            for word in words {
                songIndex[word, default: []].append(song)
            }
        }

        // Build artist index
        for artist in mockArtists {
            let normalizedName = artist.name.searchQueryNormalized
            let words = normalizedName.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }

            for word in words {
                artistIndex[word, default: []].append(artist)
            }
        }

        // Build album index
        for album in mockAlbums {
            let normalizedTitle = album.title.searchQueryNormalized
            let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }

            for word in words {
                albumIndex[word, default: []].append(album)
            }
        }
    }

    // MARK: - Public API (matches LibraryService interface)

    func search(for term: String) async -> SearchResults {
        guard !term.isEmpty else {
            return SearchResults(artists: [], albums: [], songs: [])
        }

        let normalizedTerm = term.searchQueryNormalized

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else {
                return SearchResults(artists: [], albums: [], songs: [])
            }

            let artists = self.searchArtists(term: normalizedTerm)
            let albums = self.searchAlbums(term: normalizedTerm)
            let songs = self.searchSongs(term: normalizedTerm)

            return SearchResults(artists: artists, albums: albums, songs: songs)
        }.value
    }

    private func searchSongs(term: String) -> [Song] {
        let normalizedTerm = term.searchQueryNormalized

        // Find songs where any word starts with the term
        var results = Set<Song>()

        for (word, songs) in songIndex {
            if word.hasPrefix(normalizedTerm) {
                results.formUnion(songs)
            }
        }

        return Array(results)
            .filter { song in
                let normalizedTitle = song.title.searchQueryNormalized
                let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                return words.contains { $0.hasPrefix(normalizedTerm) }
            }
            .sorted { $0.title < $1.title }
    }

    private func searchArtists(term: String) -> [Artist] {
        let normalizedTerm = term.searchQueryNormalized

        var results = Set<Artist>()

        for (word, artists) in artistIndex {
            if word.hasPrefix(normalizedTerm) {
                results.formUnion(artists)
            }
        }

        return Array(results)
            .filter { artist in
                let normalizedName = artist.name.searchQueryNormalized
                let words = normalizedName.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                return words.contains { $0.hasPrefix(normalizedTerm) }
            }
            .sorted { $0.name < $1.name }
    }

    private func searchAlbums(term: String) -> [Album] {
        let normalizedTerm = term.searchQueryNormalized

        var results = Set<Album>()

        for (word, albums) in albumIndex {
            if word.hasPrefix(normalizedTerm) {
                results.formUnion(albums)
            }
        }

        return Array(results)
            .filter { album in
                let normalizedTitle = album.title.searchQueryNormalized
                let words = normalizedTitle.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                return words.contains { $0.hasPrefix(normalizedTerm) }
            }
            .sorted { $0.title < $1.title }
    }

    func getSong(by id: MPMediaEntityPersistentID) -> Song? {
        return mockSongs.first { $0.persistentID == id }
    }

    func getPlaylists() -> [Playlist] {
        return mockPlaylists
    }

    func getSongs(forPlaylist playlistID: MPMediaEntityPersistentID) -> [Song] {
        // Return a subset of songs for mock playlists
        switch playlistID {
        case 5000: // Favorites
            return Array(mockSongs.prefix(10))
        case 5001: // Rock Classics
            return mockSongs.filter { $0.genre?.contains("Rock") == true }
        case 5002: // Latin Vibes
            return mockSongs.filter { $0.genre?.contains("Latin") == true }
        case 5003: // Workout Mix
            return Array(mockSongs.shuffled().prefix(8))
        default:
            return []
        }
    }

    func getSongs(forAlbum albumID: MPMediaEntityPersistentID) -> [Song] {
        print("🔍 MockLibraryService.getSongs(forAlbum: \(albumID))")
        print("🔍 Available albums: \(mockAlbums.map { "\($0.title) (ID: \($0.id))" }.joined(separator: ", "))")

        let album = mockAlbums.first { $0.id == albumID }
        print("🔍 Found album: \(album?.title ?? "nil")")

        guard let album = album else {
            print("🔍 No album found for ID: \(albumID)")
            return []
        }

        let filteredSongs = mockSongs.filter { $0.album == album.title }
        print("🔍 Filtered \(filteredSongs.count) songs for album '\(album.title)'")
        print("🔍 Song titles: \(filteredSongs.map { $0.title }.joined(separator: ", "))")

        return filteredSongs.sorted { $0.albumTrackNumber < $1.albumTrackNumber }
    }

    func getSongs(forArtist artistID: MPMediaEntityPersistentID) -> [Song] {
        let artist = mockArtists.first { $0.id == artistID }
        guard let artist = artist else { return [] }

        return mockSongs
            .filter { $0.artist == artist.name }
            .sorted { song1, song2 in
                if song1.album != song2.album {
                    return song1.album < song2.album
                }
                return song1.albumTrackNumber < song2.albumTrackNumber
            }
    }

    func getAllSongs() -> [Song] {
        return mockSongs
    }

    func getAllSongIDs() -> [MPMediaEntityPersistentID] {
        return mockSongs.map { $0.persistentID }
    }

    func getTotalSongCount() -> Int {
        return mockSongs.count
    }

    // MARK: - Async Methods

    func getSongIDs(forPlaylist playlistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        return getSongs(forPlaylist: playlistID).map { $0.persistentID }
    }

    func getSongIDs(forAlbum albumID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        return getSongs(forAlbum: albumID).map { $0.persistentID }
    }

    func getSongIDs(forArtist artistID: MPMediaEntityPersistentID) async -> [MPMediaEntityPersistentID] {
        return getSongs(forArtist: artistID).map { $0.persistentID }
    }

    func getMediaItems(forAlbum albumID: MPMediaEntityPersistentID) -> [MPMediaItem] {
        // Mock: return empty array since we can't create real MPMediaItems
        // The app should handle this gracefully
        return []
    }

    func getMediaItems(forArtist artistID: MPMediaEntityPersistentID) -> [MPMediaItem] {
        // Mock: return empty array since we can't create real MPMediaItems
        return []
    }

    // MARK: - Helper to convert to Song (matches LibraryService interface)

    func song(from item: MPMediaItem) -> Song {
        // This won't be called in mock mode, but we need it for interface compatibility
        return Song(
            persistentID: item.persistentID,
            title: item.title ?? "Track",
            artist: item.artist ?? "Artist",
            album: item.albumTitle ?? "Album",
            releaseDate: item.releaseDate,
            albumTrackNumber: item.albumTrackNumber,
            genre: item.genre
        )
    }
}

#endif
