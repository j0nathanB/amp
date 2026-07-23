//
//  ampTests.swift
//  ampTests
//
//  Created by zen on 7/14/25.
//

import Testing
import Foundation
import UIKit
import MediaPlayer
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

    // LibraryStore persists per-tab caches to Caches/ using atomic writes.
    // Atomic writes prevent the "app killed mid-write" failure mode where
    // a half-flushed file would decode into structurally-valid-but-wrong
    // data (populated but incomplete) on next launch — wrong artist counts
    // with no crash to signal the problem.
    //
    // This test proves the failure mode is *caught* by JSONDecoder rather
    // than silently accepted. It exists specifically so that if someone
    // later "optimizes" the write path and drops .atomic, or switches to
    // a format that tolerates truncation, this test fails and explains why.
    //
    // Do not change this test to assert success on partial decode — the
    // entire invariant is that partial data must throw.
    @Test func truncatedLibraryCacheThrowsOnDecode() throws {
        let valid = PersistedArtists(
            version: PersistedArtists.currentVersion,
            libraryLastModified: Date(),
            artists: (0..<500).map { i in
                Artist(id: UInt64(i), name: "Artist \(i)")
            },
            albumCounts: Dictionary(uniqueKeysWithValues: (0..<500).map { (UInt64($0), Int.random(in: 1...10)) })
        )

        let data = try JSONEncoder().encode(valid)
        #expect(data.count > 100, "test setup: encoded payload must be large enough that 80% truncation is meaningful")

        let truncated = data.prefix(Int(Double(data.count) * 0.8))

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(PersistedArtists.self, from: truncated)
        }
    }

    // ArtworkCache's disk layer invalidates via a single marker file
    // holding MPMediaLibrary.lastModifiedDate. These two tests pin the
    // invalidation behavior so it can't regress silently: if the marker
    // check stops firing, stale thumbnails would persist across library
    // edits forever with no crash to signal the problem (same category of
    // "silently-wrong-data" failure as the LibraryStore truncation test).
    //
    // Tests use a UUID-suffixed temp dir so they don't touch the real
    // Caches/thumbnails/.
    @Test func thumbnailCacheMarkerMismatchTriggersWipe() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("amp-test-thumbnails-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pastDate = Date(timeIntervalSinceNow: -3600)
        let currentDate = Date()

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let markerData = try JSONEncoder().encode(pastDate)
        try markerData.write(to: ThumbnailCache.markerURL(inDir: tempDir), options: .atomic)

        let dummyThumbnail = ThumbnailCache.thumbnailURL(
            inDir: tempDir,
            albumID: 123,
            size: CGSize(width: 100, height: 100)
        )
        try Data([0xFF, 0xD8, 0xFF]).write(to: dummyThumbnail)
        #expect(FileManager.default.fileExists(atPath: dummyThumbnail.path),
                "precondition: seeded thumbnail must exist before invalidation")

        ThumbnailCache.invalidateIfStale(dir: tempDir, currentLibraryDate: currentDate)

        #expect(!FileManager.default.fileExists(atPath: dummyThumbnail.path),
                "stale thumbnail should be wiped when marker is older than current library date")

        let newMarkerData = try Data(contentsOf: ThumbnailCache.markerURL(inDir: tempDir))
        let newMarkerDate = try JSONDecoder().decode(Date.self, from: newMarkerData)
        #expect(newMarkerDate >= currentDate,
                "marker should be rewritten to current library date after wipe")
    }

    @Test func thumbnailCacheMarkerFreshKeepsThumbnails() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("amp-test-thumbnails-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let currentDate = Date()

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let markerData = try JSONEncoder().encode(currentDate)
        try markerData.write(to: ThumbnailCache.markerURL(inDir: tempDir), options: .atomic)

        let dummyThumbnail = ThumbnailCache.thumbnailURL(
            inDir: tempDir,
            albumID: 456,
            size: CGSize(width: 200, height: 200)
        )
        try Data([0xFF, 0xD8, 0xFF]).write(to: dummyThumbnail)

        ThumbnailCache.invalidateIfStale(dir: tempDir, currentLibraryDate: currentDate)

        #expect(FileManager.default.fileExists(atPath: dummyThumbnail.path),
                "thumbnail should survive invalidation when marker is current")
    }

    // QueuePersistenceService moved from JSON to binary PropertyList to cut
    // cold-launch decode of ~23k UInt64 track IDs from ~489ms to single
    // digits. These three tests pin the format contract:
    //
    // 1. Round-trip preserves UInt64 values across the full unsigned range
    //    — plist integer encoding has a known gotcha where values > Int64.max
    //    can mis-roundtrip if not encoded as UInt64 explicitly. Catches any
    //    regression there before users with high-bit persistentIDs lose
    //    their queue.
    // 2. Truncated plist → decode throws. Same atomic-writes-non-negotiable
    //    pattern as the LibraryStore test; proves read-side fails cleanly
    //    when atomic-write guarantees at the write site are violated
    //    (e.g., someone drops .atomic from writeToFile).
    // 3. Legacy JSON → decodeLegacyJSON succeeds. Proves the upgrade path
    //    from pre-plist app versions doesn't silently drop users' queues.
    //    If someone later "cleans up" decodeLegacyJSON or the fallback
    //    branch in loadFromFile, this test fails.

    @Test func queueBinaryRoundTripPreservesUInt64Range() throws {
        let edgeCaseIDs: [MPMediaEntityPersistentID] = [
            0,
            1,
            UInt64.max,
            UInt64.max - 1,
            UInt64.max / 2,
            (UInt64(Int64.max)) + 1,   // first value that wraps signed Int64
            12345,
            9_876_543_210
        ]

        let queue = PersistedQueue(
            savedAt: Date(),
            trackIDs: edgeCaseIDs,
            currentIndex: 3,
            isShuffled: true,
            isLooped: false,
            originalOrder: edgeCaseIDs.reversed(),
            checksum: "test-checksum",
            playbackPosition: 42.5
        )

        let data = try QueueBinaryCoder.encode(queue)
        let decoded = try QueueBinaryCoder.decode(data)

        #expect(decoded.trackIDs == edgeCaseIDs,
                "UInt64 array must survive binary-plist round-trip including values > Int64.max")
        #expect(decoded.originalOrder == edgeCaseIDs.reversed())
        #expect(decoded.currentIndex == 3)
        #expect(decoded.isShuffled == true)
        #expect(decoded.isLooped == false)
        #expect(decoded.playbackPosition == 42.5)
        #expect(decoded.checksum == "test-checksum")
    }

    @Test func queueBinaryTruncationThrowsOnDecode() throws {
        let trackIDs: [MPMediaEntityPersistentID] = (0..<1000).map { UInt64($0) * 7919 }
        let queue = PersistedQueue(
            savedAt: Date(),
            trackIDs: trackIDs,
            currentIndex: 0,
            isShuffled: false,
            isLooped: false,
            originalOrder: trackIDs,
            checksum: "irrelevant",
            playbackPosition: nil
        )

        let data = try QueueBinaryCoder.encode(queue)
        #expect(data.count > 100, "test setup: encoded payload must be large enough that 80% truncation is meaningful")

        let truncated = data.prefix(Int(Double(data.count) * 0.8))

        #expect(throws: (any Error).self) {
            _ = try QueueBinaryCoder.decode(truncated)
        }
    }

    // CurrentTrackSnapshot is the tiny sidecar file that lets cold-launch
    // hydrate the Now Playing UI + pre-load audio before the full queue
    // restore completes. These three tests pin the format:
    //
    // 1. Round-trip across a UInt64-max persistentID — catches the same
    //    plist signed/unsigned gotcha we worried about for the queue format.
    //    If snapshot encoding ever silently mis-roundtrips high-bit IDs,
    //    users with those IDs would eagerly load the wrong track.
    // 2. Truncated plist → decode throws. Our atomic-writes-non-negotiable
    //    rule at the write site eliminates the partial-file case; this test
    //    proves the read side fails cleanly if that rule is ever violated.
    // 3. Version field schema-gates the struct. Shape changes must bump
    //    currentVersion; otherwise a user on an older build could eagerly
    //    load a track that decodes into a struct missing fields added later.

    @Test func currentTrackSnapshotRoundTrip() throws {
        let song = Song(
            persistentID: UInt64.max,
            title: "Edge Case Song",
            artist: "Some Artist",
            album: "Some Album",
            releaseDate: nil,
            albumTrackNumber: 7,
            discNumber: 1,
            genre: "Rock"
        )
        let snapshot = CurrentTrackSnapshot(
            version: CurrentTrackSnapshot.currentVersion,
            savedAt: Date(),
            song: song,
            assetURL: URL(fileURLWithPath: "/tmp/fake-audio.m4a"),
            playbackPosition: 123.45,
            currentIndex: 42
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)

        let decoded = try PropertyListDecoder().decode(CurrentTrackSnapshot.self, from: data)

        #expect(decoded.song.persistentID == UInt64.max,
                "persistentID must round-trip at the top of the UInt64 range")
        #expect(decoded.song.title == "Edge Case Song")
        #expect(decoded.assetURL.path == "/tmp/fake-audio.m4a")
        #expect(decoded.playbackPosition == 123.45)
        #expect(decoded.currentIndex == 42)
        #expect(decoded.version == CurrentTrackSnapshot.currentVersion)
    }

    @Test func currentTrackSnapshotTruncationThrowsOnDecode() throws {
        let song = Song(
            persistentID: 999999,
            title: "Test",
            artist: "Test",
            album: "Test",
            releaseDate: nil,
            albumTrackNumber: 1
        )
        let snapshot = CurrentTrackSnapshot(
            version: CurrentTrackSnapshot.currentVersion,
            savedAt: Date(),
            song: song,
            assetURL: URL(fileURLWithPath: "/tmp/x.m4a"),
            playbackPosition: 10,
            currentIndex: 0
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        #expect(data.count > 100, "test setup: encoded payload must be large enough for 80% truncation to be meaningful")

        let truncated = data.prefix(Int(Double(data.count) * 0.8))

        #expect(throws: (any Error).self) {
            _ = try PropertyListDecoder().decode(CurrentTrackSnapshot.self, from: truncated)
        }
    }

    @Test func currentTrackSnapshotVersionMismatchRejected() throws {
        let song = Song(
            persistentID: 12345,
            title: "Version Test",
            artist: "Artist",
            album: "Album",
            releaseDate: nil,
            albumTrackNumber: 1
        )
        // Simulate a snapshot written by a future schema version — older
        // builds reading this file must reject it rather than decode into a
        // partially-populated struct.
        let futureVersionSnapshot = CurrentTrackSnapshot(
            version: CurrentTrackSnapshot.currentVersion + 999,
            savedAt: Date(),
            song: song,
            assetURL: URL(fileURLWithPath: "/tmp/y.m4a"),
            playbackPosition: 0,
            currentIndex: 0
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(futureVersionSnapshot)

        // Decoding succeeds structurally (same shape), but the version guard
        // is what CurrentTrackSnapshot.loadFromDisk() checks. Verify the
        // invariant directly.
        let decoded = try PropertyListDecoder().decode(CurrentTrackSnapshot.self, from: data)
        #expect(decoded.version != CurrentTrackSnapshot.currentVersion,
                "test setup: decoded version must differ so loadFromDisk's guard is exercised")
        // loadFromDisk would return nil for this version — callers fall
        // through to full queue restore, which is the safe path.
    }

    @Test func queueBinaryDecodesLegacyJSONFormat() throws {
        let trackIDs: [MPMediaEntityPersistentID] = [100, 200, 300, UInt64.max]
        let queue = PersistedQueue(
            savedAt: Date(),
            trackIDs: trackIDs,
            currentIndex: 1,
            isShuffled: false,
            isLooped: true,
            originalOrder: trackIDs,
            checksum: "legacy-checksum",
            playbackPosition: 12.0
        )

        // Encode in the legacy JSON format that pre-plist users had on disk.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(queue)

        let decoded = try QueueBinaryCoder.decodeLegacyJSON(jsonData)

        #expect(decoded.trackIDs == trackIDs)
        #expect(decoded.currentIndex == 1)
        #expect(decoded.isLooped == true)
        #expect(decoded.checksum == "legacy-checksum")
    }

    // MARK: - Folder library synthetic ids (FOLDER_LIBRARY_TOGGLE_PLAN "testing minimum bar")

    // Pinned FNV-1a outputs. If these fail, someone changed the id
    // derivation (e.g. "simplified" to Hasher(), whose per-run seed would
    // invalidate every persisted queue/liked/snapshot id on relaunch).
    @Test func syntheticIDsAreStableAcrossRuns() async throws {
        let rootID = UUID(uuidString: "AA0E8C4A-3F17-4E9B-9D2C-111111111111")!
        #expect(FolderID.track(rootID: rootID, relativePath: "Artist/Album/01 Song.mp3") == 17817424572987264770)
        #expect(FolderID.playlist(rootID: rootID, relativePath: "Mixes/roadtrip.m3u") == 1421201391549973538)
        // Salted variants must differ from the base and from each other.
        let base = FolderID.track(rootID: rootID, relativePath: "a.mp3")
        let salt1 = FolderID.track(rootID: rootID, relativePath: "a.mp3", salt: 1)
        let salt2 = FolderID.track(rootID: rootID, relativePath: "a.mp3", salt: 2)
        #expect(base != salt1 && salt1 != salt2 && base != salt2)
    }

    // MARK: - M3U/PLS parsing (parser fixtures from the plan's testing minimum bar)

    @Test func m3uParsingSkipsCommentsAndBlanksHandlesCRLF() async throws {
        let m3u = "#EXTM3U\r\n#EXTINF:123,Artist - Title\r\nsongs/one.mp3\r\n\r\n#EXTINF:200,Other\r\ntwo.mp3\r\n"
        let entries = M3UParser.entries(in: Data(m3u.utf8), fileExtension: "m3u")
        #expect(entries == ["songs/one.mp3", "two.mp3"])
    }

    @Test func plsParsingOrdersByEntryNumber() async throws {
        let pls = """
        [playlist]
        File2=second.mp3
        Title2=Second
        File10=tenth.mp3
        File1=first.mp3
        Length1=180
        NumberOfEntries=3
        """
        let entries = M3UParser.entries(in: Data(pls.utf8), fileExtension: "pls")
        #expect(entries == ["first.mp3", "second.mp3", "tenth.mp3"])
    }

    @Test func m3uLatin1FallbackDecodes() async throws {
        // "café.mp3" in Latin-1: é = 0xE9, an invalid UTF-8 sequence.
        var bytes = Array("caf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: Array(".mp3\n".utf8))
        let entries = M3UParser.entries(in: Data(bytes), fileExtension: "m3u")
        #expect(entries == ["café.mp3"])
    }

    @Test func m3uEntryResolution() async throws {
        // Catalog: two tracks in one root; playlist lives in "Mixes/".
        let ids: [String: UInt64] = [
            "artist/album/01 song.mp3": 111,
            "artist/album/02 other.mp3": 222,
        ]
        let filenames: [String: [M3UParser.TrackCandidate]] = [
            "01 song.mp3": [.init(id: 111, normalizedPath: "artist/album/01 song.mp3")],
            "02 other.mp3": [.init(id: 222, normalizedPath: "artist/album/02 other.mp3")],
        ]
        func resolve(_ entries: [String]) -> [UInt64] {
            M3UParser.resolve(
                entries: entries,
                playlistDirectory: "Mixes",
                trackIDsByPath: ids,
                filenameCandidates: filenames
            )
        }

        // Relative to the playlist's directory, with ".." and Windows separators.
        #expect(resolve([#"..\Artist\Album\01 Song.mp3"#]) == [111])
        // Root-relative fallback when the playlist-relative join misses.
        #expect(resolve(["Artist/Album/02 Other.mp3"]) == [222])
        // Absolute path from another machine → unique suffix match.
        #expect(resolve(["/Users/zen/Music/Artist/Album/01 Song.mp3"]) == [111])
        // file:// URL with percent-encoding.
        #expect(resolve(["file:///Users/zen/Music/Artist/Album/02%20Other.mp3"]) == [222])
        // Entry outside any granted root, stream URL, missing file → dropped.
        #expect(resolve(["../../../etc/passwd.mp3", "http://example.com/radio.m3u", "gone.mp3"]).isEmpty)
        // Playlist order preserved; filename fallback catches bare names; dupes allowed.
        #expect(resolve(["02 Other.mp3", "01 Song.mp3", "02 Other.mp3"]) == [222, 111, 222])
    }

    @Test func m3uAmbiguousFilenameIsDropped() async throws {
        // Same filename in two albums: a bare-filename entry can't pick one.
        let filenames: [String: [M3UParser.TrackCandidate]] = [
            "intro.mp3": [
                .init(id: 1, normalizedPath: "a/intro.mp3"),
                .init(id: 2, normalizedPath: "b/intro.mp3"),
            ],
        ]
        let bare = M3UParser.resolve(
            entries: ["intro.mp3"],
            playlistDirectory: "",
            trackIDsByPath: ["a/intro.mp3": 1, "b/intro.mp3": 2],
            filenameCandidates: filenames
        )
        // "intro.mp3" root-relative doesn't exist; filename match is ambiguous.
        #expect(bare.isEmpty)

        // But an absolute path whose tail disambiguates resolves.
        let absolute = M3UParser.resolve(
            entries: ["/mnt/music/b/intro.mp3"],
            playlistDirectory: "",
            trackIDsByPath: ["a/intro.mp3": 1, "b/intro.mp3": 2],
            filenameCandidates: filenames
        )
        #expect(absolute == [2])
    }

    // MARK: - Apple Music .txt export parsing (the format users get from
    // Music.app's "Export Playlist…" — UTF-16, CR line endings, TSV with a
    // header row and a volume-prefixed Location column). Regression net for
    // the "playlists don't load" report where these files were silently
    // skipped as an unrecognized extension.

    // Build bytes that mirror a real export: UTF-16 (BOM), bare-CR row
    // terminators, tab-separated columns, Location last with a "Macintosh
    // HD" volume prefix and diacritics in the path.
    private static func appleMusicExport(rows: [[String]], header: [String]) -> Data {
        let text = ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\r")
        return text.data(using: .utf16)!   // includes BOM
    }

    @Test func appleMusicTextExtractsLocationStripsVolumePrefix() async throws {
        let data = Self.appleMusicExport(
            rows: [
                ["Chilanga banda", "Café Tacvba",
                 "Macintosh HD/Users/zen/Music/Music/Café Tacvba/Avalancha de éxitos/01 Chilanga banda.mp3"],
                ["No controles", "Café Tacuba",
                 "Macintosh HD/Users/zen/Music/Music/Café Tacvba/Avalancha de éxitos/03 No controles.mp3"],
            ],
            header: ["Name", "Artist", "Location"]
        )
        let entries = AppleMusicTextPlaylistParser.entries(in: data)
        // Header skipped, order preserved, volume name dropped → absolute path.
        #expect(entries == [
            "/Users/zen/Music/Music/Café Tacvba/Avalancha de éxitos/01 Chilanga banda.mp3",
            "/Users/zen/Music/Music/Café Tacvba/Avalancha de éxitos/03 No controles.mp3",
        ])
    }

    @Test func appleMusicTextFindsLocationByNameNotPosition() async throws {
        // Location is not the last column here; must be located by header name.
        let data = Self.appleMusicExport(
            rows: [["Song", "Macintosh HD/Users/zen/Music/a/b/song.mp3", "Rock"]],
            header: ["Name", "Location", "Genre"]
        )
        #expect(AppleMusicTextPlaylistParser.entries(in: data) == ["/Users/zen/Music/a/b/song.mp3"])
    }

    @Test func appleMusicTextRejectsNonExportFormat() async throws {
        // No "Location" header → not this format → empty (so the caller can
        // fall through / drop rather than inventing garbage entries).
        let data = Self.appleMusicExport(
            rows: [["Song", "Artist"]],
            header: ["Name", "Artist"]
        )
        #expect(AppleMusicTextPlaylistParser.entries(in: data).isEmpty)
        // Empty data is also handled.
        #expect(AppleMusicTextPlaylistParser.entries(in: Data()).isEmpty)
    }

    // End-to-end: an Apple Music export path (Mac tree, diacritics) resolves
    // to a device track via M3UParser.resolve's suffix match — the exact
    // pipeline buildPlaylists runs. This is what was broken.
    @Test func appleMusicTextResolvesToDeviceTrack() async throws {
        let data = Self.appleMusicExport(
            rows: [["Chilanga banda", "Café Tacvba",
                    "Macintosh HD/Users/zen/Music/Music/Café Tacvba/Avalancha de éxitos/01 Chilanga banda.mp3"]],
            header: ["Name", "Artist", "Location"]
        )
        let entries = AppleMusicTextPlaylistParser.entries(in: data)

        // Device catalog: same file under a different root path (only the
        // artist/album/file tail matches — the whole point of suffix resolution).
        let relPath = "Café Tacvba/Avalancha de éxitos/01 Chilanga banda.mp3"
        let key = M3UParser.normalizeKey(relPath)
        let resolved = M3UParser.resolve(
            entries: entries,
            playlistDirectory: "",
            trackIDsByPath: [key: 4242],
            filenameCandidates: [
                M3UParser.normalizeKey("01 Chilanga banda.mp3"):
                    [.init(id: 4242, normalizedPath: key)]
            ]
        )
        #expect(resolved == [4242])
    }

}
