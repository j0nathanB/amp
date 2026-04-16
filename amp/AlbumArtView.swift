import SwiftUI
import MediaPlayer

// Spec §8.1 + navigation amendment: front shows the artwork, back shows
// ampNavy metadata in a 2-column layout. Front tap flips to the back;
// back rows are individually tappable — artist → ArtistDetail, album →
// AlbumDetail, genre → GenreDetail. Tap on the back-face whitespace
// flips back to the front. Navigation pushes via NavigationService.push,
// which targets whichever tab is currently selected.
//
// The back face is pre-rotated 180° so it reads right-side-up at the
// flip endpoint. Opacity cross-fades the two during rotation so text is
// never mirrored. hit-testing is gated by isFlipped so only the visible
// face receives taps.

struct AlbumArtView: View {
    let song: Song?

    @ObservedObject private var nav = NavigationService.shared
    @State private var isFlipped = false
    @State private var artwork: UIImage?
    @State private var trackTotal: Int?

    var body: some View {
        ZStack {
            frontFace
                .opacity(isFlipped ? 0 : 1)
                .allowsHitTesting(!isFlipped)
            backFace
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
                .allowsHitTesting(isFlipped)
        }
        .aspectRatio(1, contentMode: .fit)
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(.easeInOut(duration: 0.4), value: isFlipped)
        .onChange(of: song?.persistentID) { _, _ in
            isFlipped = false
        }
        .task(id: song?.persistentID) {
            await loadArtwork()
            await loadTrackTotal()
        }
        .accessibilityElement()
        .accessibilityLabel(isFlipped ? "Album details" : "Album artwork")
        .accessibilityHint(isFlipped ? "Double tap a row to navigate" : "Double tap to flip")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Front face

    @ViewBuilder
    private var frontFace: some View {
        Group {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ZStack {
                    Rectangle().fill(Color.ampNavy)
                    if let initial {
                        Text(initial)
                            .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 96))
                            .foregroundStyle(Color.ampWhite)
                    }
                }
            }
        }
        .brutalistStroke()
        .contentShape(Rectangle())
        .onTapGesture { isFlipped = true }
    }

    private var initial: String? {
        guard let title = song?.album ?? song?.title, !title.isEmpty else { return nil }
        return String(title.prefix(1)).uppercased()
    }

    // MARK: - Back face

    private var backFace: some View {
        ZStack {
            // Tapping the navy background flips back to the artwork.
            Rectangle()
                .fill(Color.ampNavy)
                .contentShape(Rectangle())
                .onTapGesture { isFlipped = false }

            VStack(alignment: .leading, spacing: 22) {
                ForEach(metadataRows, id: \.label) { row in
                    MetadataRow(row: row) {
                        handleTap(row)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .brutalistStroke()
    }

    // MARK: - Metadata model

    fileprivate struct Row: Equatable {
        enum Kind: Equatable { case album, year, genre, track }
        let label: String
        let value: String
        let kind: Kind
        var isTappable: Bool {
            switch kind {
            case .album, .genre: true
            case .year, .track: false
            }
        }
    }

    private var metadataRows: [Row] {
        guard let song else { return [] }
        return [
            Row(label: "ALBUM", value: song.album.isEmpty ? "—" : song.album, kind: .album),
            Row(label: "YEAR", value: yearString, kind: .year),
            Row(label: "GENRE", value: (song.genre?.isEmpty == false ? song.genre : nil) ?? "—", kind: .genre),
            Row(label: "TRACK", value: trackString, kind: .track)
        ]
    }

    // Note: the artist is shown on the info strip *outside* the art (in
    // NowPlayingView and AlbumDetailView), so we don't duplicate an ARTIST
    // row here. Tapping the artist line below the art handles artist nav.

    private var yearString: String {
        guard let date = song?.releaseDate else { return "—" }
        return String(Calendar.current.component(.year, from: date))
    }

    private var trackString: String {
        guard let song, song.albumTrackNumber > 0 else { return "—" }
        if let total = trackTotal, total > 0 {
            return "\(song.albumTrackNumber) of \(total)"
        }
        return String(song.albumTrackNumber)
    }

    // MARK: - Taps

    private func handleTap(_ row: Row) {
        switch row.kind {
        case .album:
            navigateToAlbum()
        case .genre:
            navigateToGenre(row.value)
        case .year, .track:
            // Not navigable — flip back instead
            isFlipped = false
        }
    }

    private func navigateToAlbum() {
        guard let song else { return }
        isFlipped = false
        nav.navigateToAlbum(forTrack: song.persistentID)
    }

    private func navigateToGenre(_ genre: String) {
        isFlipped = false
        nav.navigateToGenre(genre)
    }

    // MARK: - Loading

    private func loadArtwork() async {
        guard let song else {
            artwork = nil
            return
        }
        let id = song.persistentID
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: id),
                forProperty: MPMediaItemPropertyPersistentID
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            return query.items?.first?.artwork?.image(at: CGSize(width: 800, height: 800))
        }.value
        self.artwork = image
    }

    private func loadTrackTotal() async {
        guard let song else {
            trackTotal = nil
            return
        }
        let id = song.persistentID
        let total = await Task.detached(priority: .userInitiated) { () -> Int? in
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: id),
                forProperty: MPMediaItemPropertyPersistentID
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            guard let item = query.items?.first else { return nil }
            let albumID = item.albumPersistentID
            return LibraryService.shared.getSongs(forAlbum: albumID).count
        }.value
        self.trackTotal = total
    }
}

// MARK: - MetadataRow

private struct MetadataRow: View {
    let row: AlbumArtView.Row
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(row.label)
                .font(.inversionLabel)
                .foregroundStyle(Color.ampInversionLabel)
                .frame(width: 72, alignment: .leading)
            Text(row.value)
                .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 13))
                .foregroundStyle(Color.ampWhite)
                .underline(row.isTappable, color: Color.ampInversionLabel)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isTappable ? .isButton : [])
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        AlbumArtView(song: Song(
            persistentID: 1,
            title: "Idioteque",
            artist: "Radiohead",
            album: "Kid A",
            releaseDate: Calendar.current.date(from: DateComponents(year: 2000)),
            albumTrackNumber: 8,
            discNumber: 1,
            genre: "Rock"
        ))
        .padding(24)
    }
}
