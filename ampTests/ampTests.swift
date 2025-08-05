//
//  ampTests.swift
//  ampTests
//
//  Created by zen on 7/14/25.
//

import Testing
import Foundation
@testable import amp

struct ampTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }
    
    @Test func songCreationAndEquality() async throws {
        // Test creating a Song and verifying its properties
        let persistentID: UInt64 = 12345
        let song = Song(
            persistentID: persistentID,
            title: "Test Song",
            artist: "Test Artist", 
            album: "Test Album",
            releaseDate: Date(),
            albumTrackNumber: 1
        )
        
        // Verify properties are set correctly
        #expect(song.id == persistentID)
        #expect(song.title == "Test Song")
        #expect(song.artist == "Test Artist")
        #expect(song.album == "Test Album")
        #expect(song.albumTrackNumber == 1)
        
        // Test equality - songs with same persistentID should be equal
        let sameSong = Song(
            persistentID: persistentID,
            title: "Different Title",
            artist: "Different Artist",
            album: "Different Album", 
            releaseDate: nil,
            albumTrackNumber: 2
        )
        
        #expect(song == sameSong) // Should be equal based on persistentID
    }

}
