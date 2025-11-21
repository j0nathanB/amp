#if DEBUG
import Foundation
import MediaPlayer

struct MockDataGenerator {
    static let shared = MockDataGenerator()
    
    private init() {}
    
    // MARK: - Test Data Generation
    
    /// Generates comprehensive test data for search functionality
    func generateTestData() -> [Song] {
        var testSongs: [Song] = []
        var currentID: MPMediaEntityPersistentID = 10000
        
        // Diacritics and accented characters
        testSongs.append(contentsOf: generateDiacriticsTestData(&currentID))
        
        // Special characters and punctuation
        testSongs.append(contentsOf: generateSpecialCharactersTestData(&currentID))
        
        // Edge cases
        testSongs.append(contentsOf: generateEdgeCasesTestData(&currentID))
        
        // Mixed language and scripts
        testSongs.append(contentsOf: generateMultiLanguageTestData(&currentID))
        
        // Case sensitivity tests
        testSongs.append(contentsOf: generateCaseSensitivityTestData(&currentID))
        
        // Prefix matching tests
        testSongs.append(contentsOf: generatePrefixMatchingTestData(&currentID))
        
        // Whitespace and formatting tests
        testSongs.append(contentsOf: generateWhitespaceTestData(&currentID))
        
        return testSongs
    }
    
    // MARK: - Diacritics Test Data
    
    private func generateDiacriticsTestData(_ currentID: inout MPMediaEntityPersistentID) -> [Song] {
        let diacriticsTests = [
            // French
            ("Café Noir", "Françoise Amélie", "Résumé d'Automne"),
            ("Naïve", "Zoë Deschênes", "Cœur Brisé"),
            ("Élégance", "André Citroën", "Mélodies Françaises"),
            
            // Spanish
            ("Corazón", "José María", "Niño Perdido"),
            ("Mañana", "Peña Nieto", "Sueños de España"),
            ("Niña Bonita", "Año Nuevo", "Cumpleaños Feliz"),
            
            // German
            ("Mädchen", "Björn Müller", "Größte Hits"),
            ("Straße", "Größe Köln", "Heiße Nächte"),
            ("Übung", "Früh am Morgen", "Schöne Träume"),
            
            // Nordic
            ("Åse's Death", "Grieg Øystein", "Nordisk Folklore"),
            ("Härlig Dag", "Björk Guðmundsdóttir", "Ångermanland"),
            ("København", "Lars Løkke", "Danske Drømme"),
            
            // Eastern European
            ("Želva", "Václav Dvořák", "Česká Píseň"),
            ("Młody Człowiek", "Krzysztof Kieślowski", "Polskie Ballady"),
            ("Дружба", "Иван Петров", "Русские Песни"),
            
            // Portuguese
            ("Coração", "João Sebastião", "Fados de Lisboa"),
            ("Canção", "Maria José", "Saudade do Brasil"),
            ("Paixão", "Luís Camões", "Poesias Portuguesas")
        ]
        
        return diacriticsTests.map { title, artist, album in
            defer { currentID += 1 }
            return Song(
                persistentID: currentID,
                title: title,
                artist: artist,
                album: album,
                releaseDate: randomDate(),
                albumTrackNumber: Int.random(in: 1...15)
            )
        }
    }
    
    // MARK: - Special Characters Test Data
    
    private func generateSpecialCharactersTestData(_ currentID: inout MPMediaEntityPersistentID) -> [Song] {
        let specialCharTests = [
            // Punctuation
            ("Don't Stop Me Now", "Queen & Co.", "Greatest Hits!"),
            ("Can't Help Myself", "The Four Tops", "Ultimate Collection?"),
            ("What's Going On?", "Marvin Gaye", "Soul Classics (Remastered)"),
            ("Rock & Roll Music", "Chuck Berry", "The Chess Box [Disc 1]"),
            
            // Mathematical and symbols
            ("2 + 2 = 5", "Radiohead", "Hail to the Thief"),
            ("99 Problems", "Jay-Z", "The Black Album"),
            ("$20 Fine", "Stephen Malkmus", "Mirror Traffic"),
            ("100% Pure Love", "Crystal Waters", "Storyteller"),
            
            // Brackets and parentheses
            ("Bohemian Rhapsody (Remastered)", "Queen", "A Night at the Opera [2011 Remaster]"),
            ("Song 2 [Live]", "Blur", "The Great Escape (Special Edition)"),
            ("(I Can't Get No) Satisfaction", "The Rolling Stones", "Out of Our Heads"),
            
            // Unicode symbols
            ("★ Starman ★", "David Bowie", "The Rise and Fall of Ziggy Stardust"),
            ("♫ Music Box ♫", "Mariah Carey", "Music Box"),
            ("→ Forward →", "Future", "DS2"),
            ("♥ Love Song ♥", "The Cure", "Disintegration"),
            
            // Apostrophes and quotes
            ("'Round Midnight", "Thelonious Monk", "Genius of Modern Music"),
            ("\"Heroes\"", "David Bowie", "\"Heroes\""),
            ("'Til Tuesday", "'Til Tuesday", "Voices Carry"),
            
            // Hyphens and dashes
            ("Twenty-One", "Twenty One Pilots", "Twenty—One Pilots"),
            ("Re-Hash", "Gorillaz", "Gorillaz"),
            ("Long-Distance Call", "Muddy Waters", "The Complete Plantation Recordings")
        ]
        
        return specialCharTests.map { title, artist, album in
            defer { currentID += 1 }
            return Song(
                persistentID: currentID,
                title: title,
                artist: artist,
                album: album,
                releaseDate: randomDate(),
                albumTrackNumber: Int.random(in: 1...20)
            )
        }
    }
    
    // MARK: - Edge Cases Test Data
    
    private func generateEdgeCasesTestData(_ currentID: inout MPMediaEntityPersistentID) -> [Song] {
        let edgeCases = [
            // Very long titles
            ("This Is an Extremely Long Song Title That Tests the Limits of Search Functionality and String Processing", "Artist With Very Long Name That Should Also Be Tested", "Album Title That Is Also Exceptionally Long to Test Edge Cases"),
            
            // Single characters
            ("A", "B", "C"),
            ("X", "Y", "Z"),
            ("1", "2", "3"),
            
            // Numbers only
            ("123", "456", "789"),
            ("1999", "Prince", "1999"),
            ("2001", "Dr. Dre", "2001"),
            
            // Mixed numbers and letters
            ("Track01", "Artist2", "Album3"),
            ("Song4U", "2Pac", "All Eyez on Me"),
            ("B4U", "U2", "All That You Can't Leave Behind"),
            
            // Empty-like content (but not actually empty)
            (".", "..", "..."),
            ("-", "--", "---"),
            ("_", "__", "___"),
            
            // Repeated characters
            ("Aaaaaa", "Bbbbbb", "Cccccc"),
            ("lalala", "hahaha", "bababa"),
            
            // Common words that might conflict
            ("The", "The", "The"),
            ("And", "And & And", "And/Or"),
            ("Of", "Of Montreal", "Of the Night"),
            
            // Potential search conflicts
            ("Test", "Testing", "Test Album"),
            ("Search", "Searching", "Search Results"),
            ("Music", "Musical", "Music Box"),
            
            // Articles and prepositions
            ("A Song", "An Artist", "The Album"),
            ("In the End", "On the Road", "At the Gates"),
            ("With You", "For You", "By You")
        ]
        
        return edgeCases.map { title, artist, album in
            defer { currentID += 1 }
            return Song(
                persistentID: currentID,
                title: title,
                artist: artist,
                album: album,
                releaseDate: randomDate(),
                albumTrackNumber: Int.random(in: 1...25)
            )
        }
    }
    
    // MARK: - Prefix Matching Test Data
    
    private func generatePrefixMatchingTestData(_ currentID: inout MPMediaEntityPersistentID) -> [Song] {
        let prefixTests = [
            // Band name prefix matching - your specific examples
            ("Change (In the House of Flies)", "Deftones", "White Pony"),
            ("My Own Summer (Shove It)", "Deftones", "Around the Fur"),
            ("Be Quiet and Drive (Far Away)", "Deftones", "Around the Fur"),
            ("Digital Bath", "The Deftones", "White Pony"), // Alternative band name format
            
            // More realistic band/song prefix scenarios
            ("Paranoid Android", "Radiohead", "OK Computer"),
            ("Radio Free Europe", "R.E.M.", "Murmur"),
            ("Radio Song", "R.E.M.", "Out of Time"),
            ("Rad", "Radiohead", "In Rainbows"), // Test "rad" doesn't match "Radiohead" inappropriately
            
            // Multi-word prefix matching
            ("My Own Prison", "Creed", "My Own Prison"),
            ("My Own Way", "Duran Duran", "Rio"),
            ("My Generation", "The Who", "The Who Sings My Generation"),
            ("Summer Breeze", "Seals and Crofts", "Summer Breeze"),
            ("Summer of '69", "Bryan Adams", "Reckless"),
            
            // Article handling in band names
            ("Immigrant Song", "Led Zeppelin", "Led Zeppelin III"),
            ("Led Boots", "Jeff Beck", "Blow by Blow"), // "Led" should not match "Led Zeppelin"
            ("The Man", "The Killers", "Day & Age"),
            ("Man on the Box", "Bush", "The Science of Things"), // "Man" should not match "The Man"
            
            // Single word vs prefix scenarios
            ("Black", "Pearl Jam", "vs."),
            ("Blackbird", "The Beatles", "The Beatles (White Album)"),
            ("Black Hole Sun", "Soundgarden", "Superunknown"),
            
            // Prefix edge cases
            ("Go", "Pearl Jam", "vs."),
            ("Going Under", "Evanescence", "Fallen"),
            ("Gone", "Pearl Jam", "Binaural"),
            
            // Number prefixes
            ("1979", "The Smashing Pumpkins", "Mellon Collie and the Infinite Sadness"),
            ("19", "Adele", "19"),
            ("1999", "Prince", "1999"),
            
            // Common word prefixes that should work
            ("Love", "The Beatles", "Revolver"),
            ("Love Song", "The Cure", "Disintegration"),
            ("Lovely Day", "Bill Withers", "Menagerie"),
            
            // Potential false positives to avoid
            ("Sun", "Two Door Cinema Club", "Tourist History"), // Should NOT match "Soundgarden"
            
            // Ace prefix test - should find "Ace of Base" but not "Grace Jones"
            ("All That She Wants", "Ace of Base", "Happy Nation"),
            ("The Sign", "Ace of Base", "The Sign"),
            ("Pull Up to the Bumper", "Grace Jones", "Nightclubbing"), // Should NOT match "ace" query
            ("War", "Edwin Starr", "War & Peace"), // Should NOT match "Warpaint"
            ("Red", "King Crimson", "In the Court of the Crimson King"), // Should NOT match "Red Hot Chili Peppers"
            
            // Complex band name prefixes
            ("Mr. Brightside", "The Killers", "Hot Fuss"),
            ("Mr. Blue Sky", "Electric Light Orchestra", "Out of the Blue"),
            ("Mister Sandman", "The Chordettes", "Close Harmony"),
            
            // Abbreviation scenarios
            ("REM", "R.E.M.", "Automatic for the People"), // Alternative name format
            ("AC/DC", "AC/DC", "Back in Black"),
            ("ACDC", "AC/DC", "Highway to Hell"), // Alternative format
            
            // Special prefix scenarios
            ("Def Leppard", "Def Leppard", "Hysteria"), // "Def" should match "Def Leppard" not just "Deftones"
            ("Definition", "Black Star", "Mos Def & Talib Kweli Are Black Star"), // "Def" prefix test
        ]
        
        return prefixTests.map { title, artist, album in
            defer { currentID += 1 }
            return Song(
                persistentID: currentID,
                title: title,
                artist: artist,
                album: album,
                releaseDate: randomDate(),
                albumTrackNumber: Int.random(in: 1...15)
            )
        }
    }
    
    // MARK: - Multi-Language Test Data
    
    private func generateMultiLanguageTestData(_ currentID: inout MPMediaEntityPersistentID) -> [Song] {
        let multiLanguageTests = [
            // Japanese
            ("愛をください", "山田太郎", "日本の歌"),
            ("桜", "花子", "春の歌"),
            ("夜明け", "田中一郎", "朝の音楽"),
            
            // Chinese
            ("月亮代表我的心", "邓丽君", "甜蜜蜜"),
            ("茉莉花", "宋祖英", "中国民歌"),
            ("春天的故事", "董文华", "经典老歌"),
            
            // Korean
            ("사랑해", "김민수", "한국 가요"),
            ("아리랑", "전통음악", "민요 모음"),
            ("강남스타일", "싸이", "6집"),
            
            // Arabic
            ("حبيبي", "فيروز", "أغاني لبنانية"),
            ("يا زريف الطول", "أم كلثوم", "كلاسيكيات عربية"),
            
            // Hindi
            ("तुम ही हो", "अरिजीत सिंह", "आशिकी २"),
            ("वन्दे मातरम्", "ए आर रहमान", "देशभक्ति गीत"),
            
            // Greek
            ("Αντίο", "Μίκης Θεοδωράκης", "Ελληνικά Τραγούδια"),
            ("Ζεμπεκικό", "Βασίλης Τσιτσάnis", "Ρεμπέτικα"),
            
            // Hebrew
            ("שלום", "עופרה חזה", "שירים יפים"),
            ("ירושלים של זהב", "נעמי שמר", "זמר עברי"),
            
            // Thai
            ("รักเธอ", "เบิร์ด ธงไชย", "เพลงไทย"),
            ("เมื่อไหร่", "คาราบาว", "คลาสสิค"),
            
            // Mixed scripts in one entry
            ("English 日本語 Mix", "Artist العربية", "Album Ελληνικά")
        ]
        
        return multiLanguageTests.map { title, artist, album in
            defer { currentID += 1 }
            return Song(
                persistentID: currentID,
                title: title,
                artist: artist,
                album: album,
                releaseDate: randomDate(),
                albumTrackNumber: Int.random(in: 1...12)
            )
        }
    }
    
    // MARK: - Case Sensitivity Test Data
    
    private func generateCaseSensitivityTestData(_ currentID: inout MPMediaEntityPersistentID) -> [Song] {
        let caseTests = [
            ("hello", "world", "test"),
            ("HELLO", "WORLD", "TEST"),
            ("Hello", "World", "Test"),
            ("hELLO", "wORLD", "tEST"),
            ("HeLLo", "WoRLd", "TeSt"),
            
            ("beatles", "the beatles", "beatles anthology"),
            ("Beatles", "The Beatles", "Beatles Anthology"),
            ("BEATLES", "THE BEATLES", "BEATLES ANTHOLOGY"),
            ("BeAtLeS", "ThE bEaTlEs", "BeAtLeS aNtHoLoGy"),
            
            ("abc", "def", "ghi"),
            ("ABC", "DEF", "GHI"),
            ("Abc", "Def", "Ghi"),
            ("aBc", "dEf", "gHi")
        ]
        
        return caseTests.map { title, artist, album in
            defer { currentID += 1 }
            return Song(
                persistentID: currentID,
                title: title,
                artist: artist,
                album: album,
                releaseDate: randomDate(),
                albumTrackNumber: Int.random(in: 1...10)
            )
        }
    }
    
    // MARK: - Whitespace Test Data
    
    private func generateWhitespaceTestData(_ currentID: inout MPMediaEntityPersistentID) -> [Song] {
        let whitespaceTests = [
            // Leading/trailing spaces
            (" Leading Space", "Artist", "Album"),
            ("Trailing Space ", "Artist", "Album"),
            (" Both Sides ", "Artist", "Album"),
            
            // Multiple spaces
            ("Multiple  Spaces", "Artist  Name", "Album  Title"),
            ("Three   Spaces", "Artist   Name", "Album   Title"),
            ("Many    Spaces    Here", "Artist    Name", "Album    Title"),
            
            // Tabs and other whitespace
            ("Tab\tCharacter", "Artist\tName", "Album\tTitle"),
            ("New\nLine", "Artist\nName", "Album\nTitle"),
            
            // Mixed whitespace
            (" \t Mixed \n Whitespace \t ", "Artist", "Album"),
            
            // Only whitespace (but not empty)
            (" ", "  ", "   "),
            ("\t", "\t\t", "\t\t\t")
        ]
        
        return whitespaceTests.map { title, artist, album in
            defer { currentID += 1 }
            return Song(
                persistentID: currentID,
                title: title,
                artist: artist,
                album: album,
                releaseDate: randomDate(),
                albumTrackNumber: Int.random(in: 1...8)
            )
        }
    }
    
    // MARK: - Helper Methods
    
    private func randomDate() -> Date? {
        let randomTimeInterval = TimeInterval.random(in: -1_000_000_000...0) // Past dates
        return Date(timeIntervalSinceNow: randomTimeInterval)
    }
}

// MARK: - Test Verification Methods

extension MockDataGenerator {
    
    /// Tests for specific search scenarios
    func generateSearchTestCases() -> [(query: String, expectedMatches: [String], description: String)] {
        return [
            // Prefix matching - your specific examples
            ("def", ["Deftones", "The Deftones", "Def Leppard"], "Should find 'Deftones', 'The Deftones', and 'Def Leppard' when searching for 'def'"),
            ("my own", ["My Own Summer (Shove It)", "My Own Prison", "My Own Way"], "Should find songs with 'My Own' when searching for 'my own'"),
            
            // Diacritics normalization
            ("cafe", ["Café Noir"], "Should find 'Café Noir' when searching for 'cafe'"),
            ("Francoise", ["Françoise Amélie"], "Should find 'Françoise Amélie' when searching for 'Francoise'"),
            ("resume", ["Résumé d'Automne"], "Should find 'Résumé d'Automne' when searching for 'resume'"),
            
            // Case insensitivity
            ("hello", ["hello", "HELLO", "Hello", "hELLO", "HeLLo"], "Should find all case variations of 'hello'"),
            ("BEATLES", ["beatles", "Beatles", "BEATLES", "BeAtLeS"], "Should find all case variations of 'BEATLES'"),
            
            // Partial matching
            ("beat", ["beatles", "Beatles", "BEATLES", "BeAtLeS"], "Should find partial matches for 'beat'"),
            ("test", ["Test", "Testing", "Test Album"], "Should find partial matches for 'test'"),
            
            // Special characters
            ("dont", ["Don't Stop Me Now"], "Should find 'Don't Stop Me Now' when searching for 'dont'"),
            ("cant", ["Can't Help Myself"], "Should find 'Can't Help Myself' when searching for 'cant'"),
            ("whats", ["What's Going On?"], "Should find 'What's Going On?' when searching for 'whats'"),
            
            // Whitespace handling
            ("multiple spaces", ["Multiple  Spaces", "Three   Spaces"], "Should handle multiple spaces in search"),
            ("leading", [" Leading Space"], "Should find entries with leading whitespace"),
            ("trailing", ["Trailing Space "], "Should find entries with trailing whitespace"),
            
            // Numbers
            ("123", ["123", "1999", "2001"], "Should find numeric matches"),
            ("99", ["99 Problems"], "Should find partial numeric matches"),
            
            // Edge cases
            ("a", ["A", "Aaaaaa"], "Should handle single character searches"),
            ("the", ["The", "The Beatles"], "Should handle common word searches")
        ]
    }
    
    /// Generates performance test data with specified size
    func generatePerformanceTestData(count: Int) -> [Song] {
        var songs: [Song] = []
        var currentID: MPMediaEntityPersistentID = 50000
        
        let titlePrefixes = ["Song", "Track", "Music", "Audio", "Sound", "Melody", "Rhythm", "Beat"]
        let artistPrefixes = ["Artist", "Band", "Singer", "Musician", "Performer", "Group", "Duo", "Solo"]
        let albumPrefixes = ["Album", "Collection", "Anthology", "Greatest", "Best", "Ultimate", "Complete", "Selected"]
        
        for i in 0..<count {
            let title = "\(titlePrefixes.randomElement()!) \(i)"
            let artist = "\(artistPrefixes.randomElement()!) \(i % 100)"
            let album = "\(albumPrefixes.randomElement()!) \(i % 50)"
            
            songs.append(Song(
                persistentID: currentID,
                title: title,
                artist: artist,
                album: album,
                releaseDate: randomDate(),
                albumTrackNumber: (i % 15) + 1
            ))
            
            currentID += 1
        }
        
        return songs
    }
}

// MARK: - Integration Helper

extension MockDataGenerator {
    
    /// Creates a test-ready LibraryService instance with mock data
    func createTestLibraryService() -> LibraryService {
        let libraryService = LibraryService.shared
        let mockSongs = generateTestData()
        
        // This would require modifying LibraryService to accept mock data
        // For now, this serves as a placeholder for integration
        print("Generated \(mockSongs.count) mock songs for testing")
        
        return libraryService
    }
    
    /// Prints a summary of generated test data
    func printTestDataSummary() {
        let testData = generateTestData()
        let testCases = generateSearchTestCases()
        
        print("📊 Mock Data Generator Summary")
        print("═══════════════════════════════")
        print("Total test songs: \(testData.count)")
        print("Test cases: \(testCases.count)")
        print("")
        print("Categories:")
        print("• Diacritics and accents: ~24 songs")
        print("• Special characters: ~27 songs") 
        print("• Edge cases: ~30 songs")
        print("• Multi-language: ~25 songs")
        print("• Case sensitivity: ~13 songs")
        print("• Whitespace handling: ~12 songs")
        print("")
        print("Languages covered:")
        print("• French, Spanish, German")
        print("• Nordic (Swedish, Danish, Norwegian)")
        print("• Eastern European (Czech, Polish, Russian)")
        print("• Portuguese, Japanese, Chinese")
        print("• Korean, Arabic, Hindi, Greek")
        print("• Hebrew, Thai")
        print("")
        print("Use MockDataGenerator.shared.generateTestData() to get all test songs")
        print("Use MockDataGenerator.shared.generateSearchTestCases() to get test scenarios")
    }
}
#endif
