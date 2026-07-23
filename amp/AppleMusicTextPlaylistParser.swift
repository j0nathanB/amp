import Foundation

// Apple Music's "File ▸ Library ▸ Export Playlist…" text export (.txt).
// NOT an m3u/pls — it's a tab-separated spreadsheet dump: a header row
// naming ~30 columns (Name, Artist, …, Location) followed by one row per
// track. Encoded UTF-16 (BOM) with bare-CR line terminators, so the
// WinAmp-era assumptions baked into M3UParser (UTF-8/Latin-1, one path
// per line) don't apply — hence a dedicated parser.
//
// We extract only the Location column and hand the raw path strings to
// M3UParser.resolve, which already does filename/suffix matching across
// roots — the right tool, since a Mac-side Location never matches a
// device path directly but its artist/album/file tail does.
enum AppleMusicTextPlaylistParser {

    // Data → Location paths in playlist order. Empty when the file isn't
    // this format (no decodable text, or no "Location" header column).
    static func entries(in data: Data) -> [String] {
        guard let text = decode(data) else { return [] }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let header = lines.first else { return [] }

        // Find Location by name, not position: column order can vary with
        // the exporting app's version / locale.
        let columns = header.components(separatedBy: "\t")
        guard let locationIndex = columns.firstIndex(of: "Location") else { return [] }

        return lines.dropFirst().compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard locationIndex < fields.count else { return nil }
            return absolutePath(from: fields[locationIndex])
        }
    }

    // BOM-bearing UTF-16 first (String honors the byte-order mark); fall
    // back to UTF-8 for the "Unicode Text" export variant. No Latin-1
    // fallback — unlike raw m3u, this format is always Unicode.
    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf16) ?? String(data: data, encoding: .utf8)
    }

    // Location is a volume-relative display path: the first component is
    // the volume name ("Macintosh HD", or an external drive's name), the
    // rest is the real tree. Drop the volume name and prepend "/" so the
    // entry reads as an absolute POSIX path — that flips on M3UParser's
    // suffix matching (which disambiguates by the artist/album/file tail)
    // instead of the weaker bare-filename fallback.
    private static func absolutePath(from location: String) -> String? {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return nil }
        return "/" + components.dropFirst().joined(separator: "/")
    }
}
