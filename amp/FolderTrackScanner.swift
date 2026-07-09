import Foundation
import AVFoundation

// Stateless folder-scan mechanics (Phase 3 of
// dev/FOLDER_LIBRARY_TOGGLE_PLAN.md): recursive audio-file discovery and
// AVAsset tag extraction with bounded concurrency. Orchestration (roots,
// scopes, catalog assembly, persistence) lives in FolderLibraryService.
//
// Phase 3 extracts title / artist / album / album-artist / genre /
// duration — what the flat Songs list and Phase 4 grouping need.
// Track/disc numbers (format-specific binary keys) and embedded artwork
// arrive with Phase 4's album detail work.
enum FolderTrackScanner {

    // Plan decision #8: MP3, M4A (AAC + ALAC), WAV, AIFF, FLAC.
    // OGG/Opus have no native iOS decoder — filtered at discovery.
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac"
    ]

    // Matches A-series efficiency cores + I/O overlap; the old plan's
    // profiling note. Tunable.
    private static let maxConcurrentExtractions = 6

    struct DiscoveredFile {
        let url: URL
        let relativePath: String
    }

    // MARK: - Discovery

    // Recursive walk under an (already scope-granted) root. Hidden files
    // skipped; `.icloud` placeholder sidecars are hidden, so undownloaded
    // iCloud items simply don't appear until Phase 6's download-on-demand.
    static func audioFiles(under rootURL: URL) -> [DiscoveredFile] {
        let rootPath = rootURL.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [DiscoveredFile] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            results.append(DiscoveredFile(
                url: url,
                relativePath: String(path.dropFirst(rootPath.count + 1))
            ))
        }
        // Deterministic order in, deterministic catalog out.
        return results.sorted { $0.relativePath < $1.relativePath }
    }

    // MARK: - Extraction

    // Bounded-concurrency tag extraction. onProgress reports the number of
    // files completed since the last report (delta, not total).
    static func extractTracks(
        from files: [DiscoveredFile],
        rootID: UUID,
        onProgress: @escaping (Int) -> Void
    ) async -> [FolderTrack] {
        var tracks: [FolderTrack] = []
        tracks.reserveCapacity(files.count)

        var iterator = files.makeIterator()
        await withTaskGroup(of: FolderTrack.self) { group in
            var inFlight = 0
            while inFlight < maxConcurrentExtractions, let file = iterator.next() {
                group.addTask { await extractTrack(from: file, rootID: rootID) }
                inFlight += 1
            }
            for await track in group {
                tracks.append(track)
                onProgress(1)
                if let next = iterator.next() {
                    group.addTask { await extractTrack(from: next, rootID: rootID) }
                }
            }
        }
        return tracks
    }

    private static func extractTrack(from file: DiscoveredFile, rootID: UUID) async -> FolderTrack {
        let asset = AVURLAsset(url: file.url)

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var genre: String?
        var duration: TimeInterval = 0

        if let loaded = try? await asset.load(.duration), loaded.seconds.isFinite {
            duration = loaded.seconds
        }

        if let common = try? await asset.load(.commonMetadata) {
            title = await stringValue(in: common, for: .commonIdentifierTitle)
            artist = await stringValue(in: common, for: .commonIdentifierArtist)
            album = await stringValue(in: common, for: .commonIdentifierAlbumName)
            genre = await stringValue(in: common, for: .commonIdentifierType)
        }

        // Album-artist is format-specific (ID3 TPE2 / iTunes aART); walk
        // the available formats only if the common pass left it unknown.
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats where albumArtist == nil {
                guard let items = try? await asset.loadMetadata(for: format) else { continue }
                albumArtist = await stringValue(in: items, for: .id3MetadataBand)
                if albumArtist == nil {
                    albumArtist = await stringValue(in: items, for: .iTunesMetadataAlbumArtist)
                }
            }
        }

        // Filename fallback for untagged files: "01 Artist - Title.mp3" /
        // "Artist - Title.mp3" / bare stem.
        if title == nil || title?.isEmpty == true {
            let parsed = parseFilename(file.relativePath)
            title = parsed.title
            if artist == nil { artist = parsed.artist }
        }

        let resolvedTitle = title?.trimmingCharacters(in: .whitespaces) ?? "Track"
        let resolvedArtist = artist?.trimmingCharacters(in: .whitespaces) ?? "Artist"
        let resolvedAlbum = album?.trimmingCharacters(in: .whitespaces) ?? "Album"
        let resolvedAlbumArtist = albumArtist?.trimmingCharacters(in: .whitespaces) ?? resolvedArtist

        let song = Song(
            persistentID: FolderID.track(rootID: rootID, relativePath: file.relativePath),
            title: resolvedTitle,
            artist: resolvedArtist,
            album: resolvedAlbum,
            releaseDate: nil,
            albumTrackNumber: 0,
            discNumber: 1,
            genre: genre
        )

        return FolderTrack(
            song: song,
            rootID: rootID,
            relativePath: file.relativePath,
            duration: duration,
            albumArtist: resolvedAlbumArtist,
            albumID: FolderID.album(albumArtist: resolvedAlbumArtist, album: resolvedAlbum),
            artistID: FolderID.artist(name: resolvedAlbumArtist)
        )
    }

    private static func stringValue(
        in items: [AVMetadataItem],
        for identifier: AVMetadataIdentifier
    ) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else {
            return nil
        }
        guard let value = try? await item.load(.stringValue) else { return nil }
        return value
    }

    // MARK: - Filename fallback

    // "01 Artist - Title" → (Artist, Title); "Artist - Title" → same;
    // anything else → stem as title. Leading track digits + separators
    // are stripped first.
    static func parseFilename(_ relativePath: String) -> (title: String, artist: String?) {
        var stem = (relativePath as NSString).lastPathComponent
        stem = (stem as NSString).deletingPathExtension

        // Strip a leading track number: 1-3 digits followed by separators.
        var trimmed = Substring(stem)
        let digits = trimmed.prefix(while: { $0.isNumber })
        if !digits.isEmpty && digits.count <= 3 {
            let afterDigits = trimmed.dropFirst(digits.count)
            let separators = afterDigits.prefix(while: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            if !separators.isEmpty {
                trimmed = afterDigits.dropFirst(separators.count)
            }
        }

        let cleaned = String(trimmed).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return (stem, nil) }

        if let range = cleaned.range(of: " - ") {
            let artist = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty && !title.isEmpty {
                return (title, artist)
            }
        }
        return (cleaned, nil)
    }
}
