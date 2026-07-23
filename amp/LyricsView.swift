import SwiftUI
import MediaPlayer

// Spec §7.7: pushed view from Now Playing. Back button + yellow "Lyrics"
// block + centered context row ({title} · {artist} · {album}) + scrollable
// body of lyric lines, each 44 tall, centered horizontally, .bodyBrutalist.
//
// Phase F is unsynced-only. Lyrics come from MPMediaItem.lyrics (ID3 USLT).
// Synced lyrics (navy-inverted current-line strip + auto-scroll) are a
// later polish once we have a time-synced source.
//
// Empty state per §13: "No lyrics available."

struct LyricsView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @Environment(\.dismiss) private var dismiss

    @State private var lyrics: String?
    @State private var loadedTrackID: MPMediaEntityPersistentID?

    var body: some View {
        VStack(spacing: 0) {
            chrome
            titleBlock
            contextRow
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: audioPlayer.currentTrack?.persistentID) {
            await loadLyrics()
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack {
            BackButton { dismiss() }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private var titleBlock: some View {
        ViewTitleBlock("Lyrics")
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
    }

    private var contextRow: some View {
        let track = audioPlayer.currentTrack
        let parts = [track?.title, track?.artist, track?.album]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return Text(parts.joined(separator: "  ·  "))
            .font(.metadata)
            .foregroundStyle(Color.ampMutedText)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if let lyrics, !lyrics.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(lyricsLines(lyrics), id: \.offset) { pair in
                        Text(pair.line)
                            .font(.bodyBrutalist)
                            .foregroundStyle(Color.ampBlack)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .overflowGradientBars()
        } else {
            VStack {
                Spacer()
                Text("No lyrics available.")
                    .font(.metadata)
                    .foregroundStyle(Color.ampMutedText)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func lyricsLines(_ text: String) -> [(offset: Int, line: String)] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { ($0.offset, String($0.element)) }
    }

    // LRC-style lyric files — and, as here, USLT frames tagged like them —
    // prefix each line with a time code: [mm:ss.xx]. We render unsynced
    // text, so strip those for display only; the file bytes are untouched.
    // Matched by shape, not a fixed digit count, so every numeral variant
    // goes: 1–2 digit minutes, an optional hours field, 2–3 digit or absent
    // fractions, '.' or ':' before the fraction, and repeated tags on one
    // line ([00:15.82][00:30.00]). The interior is constrained to
    // digits/colons/dots/whitespace, so word markers like [Chorus] or
    // [Verse 1] are left intact.
    private static let leadingTimestamps = /^\s*(?:\[[\d.:\s]+\]\s*)+/

    private static func stripLeadingTimestamps(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.replacing(leadingTimestamps, with: "")) }
            .joined(separator: "\n")
    }

    // MARK: - Loading

    private func loadLyrics() async {
        guard let id = audioPlayer.currentTrack?.persistentID else {
            lyrics = nil
            loadedTrackID = nil
            return
        }
        if loadedTrackID == id { return }
        // Folder mode's embedded-lyrics read needs an AVAsset opened under
        // the root's security scope, which wants to be async — the
        // LibrarySource.getLyrics protocol method is synchronous (fine for
        // MusicLibrarySource's MPMediaItem.lyrics lookup), so folder tracks
        // go straight to FolderLibraryService instead. Same per-mode
        // dispatch shape as ArtworkCache.artwork's folder branch.
        let text: String?
        if LibraryModeService.shared.mode == .folder {
            text = await FolderLibraryService.shared.lyrics(forTrack: id)
        } else {
            text = await Task.detached(priority: .userInitiated) {
                LibraryService.shared.getLyrics(forTrack: id)
            }.value
        }
        self.lyrics = text.map(Self.stripLeadingTimestamps)
        self.loadedTrackID = id
    }
}
