import Foundation

// .m3u / .m3u8 / .pls playlist parsing and entry resolution (Phase 5 of
// dev/FOLDER_LIBRARY_TOGGLE_PLAN.md). Pure functions over bytes + lookup
// maps — file discovery, scope brackets, and catalog assembly stay in
// FolderLibraryService / FolderTrackScanner.
//
// Resolution policy (plan decision #3 + open-risk note): entries resolve
// against scanned tracks by normalized path — relative to the playlist
// file's directory, then root-relative, then a filename match for
// absolute paths written on another machine. Unresolved entries (files
// outside any granted root, stream URLs, ambiguous filenames) are
// dropped.
enum M3UParser {

    // MARK: - Parsing (bytes → raw entry strings, in playlist order)

    static func entries(in data: Data, fileExtension: String) -> [String] {
        guard let text = decode(data) else { return [] }
        return fileExtension.lowercased() == "pls"
            ? plsEntries(in: text)
            : m3uEntries(in: text)
    }

    // Playlists predate UTF-8 discipline: WinAmp-era .m3u and .pls are
    // often Latin-1. Try UTF-8 strictly first (it rejects invalid byte
    // sequences, so misdetection is impossible); fall back to Latin-1,
    // which accepts any byte string.
    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // CharacterSet splitting operates on unicode scalars — required here
    // because "\r\n" is a single grapheme cluster in Swift, so
    // split(separator: "\n") silently fails to split CRLF files (the
    // whole playlist becomes one "line"). Empty fragments (e.g. between
    // \r and \n) are dropped by the callers' filters.
    private static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    // M3U: every non-blank, non-comment line is a path. #EXTM3U/#EXTINF
    // and any other #-directive are comments.
    private static func m3uEntries(in text: String) -> [String] {
        lines(of: text).filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // PLS: INI-style FileN=path keys, ordered by N (TitleN/LengthN/
    // NumberOfEntries/[playlist] ignored). File10 must sort after File2,
    // so order numerically, not by line position.
    private static func plsEntries(in text: String) -> [String] {
        var numbered: [(index: Int, path: String)] = []
        for line in lines(of: text) {
            guard line.lowercased().hasPrefix("file"),
                  let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.index(line.startIndex, offsetBy: 4)..<equals]
            guard let index = Int(key) else { continue }
            let path = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { numbered.append((index, path)) }
        }
        return numbered.sorted { $0.index < $1.index }.map { $0.path }
    }

    // MARK: - Resolution (raw entries → track ids)

    // One scanned track as a resolution target. normalizedPath is the
    // root-relative path run through normalizeKey.
    struct TrackCandidate {
        let id: UInt64
        let normalizedPath: String
    }

    // trackIDsByPath: the playlist's OWN root, normalized root-relative
    // path → id (relative entries can only mean files in that root).
    // filenameCandidates: normalized filename → candidates across ALL
    // roots, so an absolute entry can land in a sibling root. All keys
    // must come from normalizeKey.
    static func resolve(
        entries: [String],
        playlistDirectory: String,
        trackIDsByPath: [String: UInt64],
        filenameCandidates: [String: [TrackCandidate]]
    ) -> [UInt64] {
        entries.compactMap {
            resolveEntry(
                $0,
                playlistDirectory: playlistDirectory,
                trackIDsByPath: trackIDsByPath,
                filenameCandidates: filenameCandidates
            )
        }
    }

    private static func resolveEntry(
        _ rawEntry: String,
        playlistDirectory: String,
        trackIDsByPath: [String: UInt64],
        filenameCandidates: [String: [TrackCandidate]]
    ) -> UInt64? {
        let entry = cleanEntry(rawEntry)
        guard !entry.isEmpty else { return nil }

        let isAbsolute = entry.hasPrefix("/")
        if !isAbsolute {
            // Relative to the playlist file's directory ("../" collapsed) …
            if let id = trackIDsByPath[normalizeKey(join(playlistDirectory, entry))] {
                return id
            }
            // … or written relative to the root itself.
            if let id = trackIDsByPath[normalizeKey(join("", entry))] {
                return id
            }
        }

        // Absolute path (or relative miss): match by filename, preferring
        // the candidate whose root-relative path is a suffix of the entry —
        // an absolute path from another machine still ends in the same
        // artist/album/file tail. A bare filename match only counts when
        // unambiguous.
        let normalized = normalizeKey(entry)
        guard let filename = normalized.split(separator: "/").last.map(String.init),
              let candidates = filenameCandidates[filename] else { return nil }

        if isAbsolute {
            let suffixMatches = candidates.filter {
                normalized.hasSuffix("/" + $0.normalizedPath)
            }
            if suffixMatches.count == 1 { return suffixMatches[0].id }
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    // MARK: - Path normalization

    // Windows separators, file:// URLs with percent-encoding, and stream
    // URLs all appear in the wild. http(s) entries are unresolvable by
    // definition → cleaned to "" and dropped.
    private static func cleanEntry(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespaces)
        let lower = path.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return "" }
        if lower.hasPrefix("file://") {
            path = String(path.dropFirst("file://".count))
            if let host = path.firstIndex(of: "/"), host != path.startIndex {
                // file://localhost/… — drop the host component.
                path = String(path[host...])
            }
            path = path.removingPercentEncoding ?? path
        }
        return path.replacingOccurrences(of: "\\", with: "/")
    }

    // Join + collapse "." and ".." lexically. ".." escaping above the root
    // yields a key that can never match a track — outside-root entries
    // drop out naturally.
    private static func join(_ directory: String, _ entry: String) -> String {
        var components: [String] = directory.split(separator: "/").map(String.init)
        for part in entry.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                if components.isEmpty { return "\u{0}outside-root" }
                components.removeLast()
            default: components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    // Case-insensitive, Unicode-composition-insensitive comparison key.
    // macOS filesystems hand back NFD filenames while playlist text is
    // usually NFC — precompose both sides or "Beyoncé.mp3" never matches.
    static func normalizeKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
