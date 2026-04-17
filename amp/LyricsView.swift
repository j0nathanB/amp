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

    // MARK: - Loading

    private func loadLyrics() async {
        guard let id = audioPlayer.currentTrack?.persistentID else {
            lyrics = nil
            loadedTrackID = nil
            return
        }
        if loadedTrackID == id { return }
        let text = await Task.detached(priority: .userInitiated) {
            LibraryService.shared.getLyrics(forTrack: id)
        }.value
        self.lyrics = text
        self.loadedTrackID = id
    }
}
