import SwiftUI
import MediaPlayer

// Spec §8.1: single tap on the album art flips it on the Y axis, ~400ms
// ease-in-out. Front is the artwork; back is ampNavy with a 2-column
// metadata block (label / value). No pause/play on tap — the art gesture
// is reserved for the flip. Used by Now Playing (§7.6) and Album Detail
// (§7.4, landing in Phase E/later).
//
// Pattern for the flip: both faces live in a ZStack. The back face is
// pre-rotated 180° so that when the outer container hits 180° (fully
// flipped), the back face is right-side-up. Opacity cross-fades the two
// during rotation so text on the back never appears mirrored.

struct AlbumArtView: View {
    let song: Song?

    @State private var isFlipped = false
    @State private var artwork: UIImage?

    var body: some View {
        ZStack {
            frontFace
                .opacity(isFlipped ? 0 : 1)
            backFace
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
        }
        .aspectRatio(1, contentMode: .fit)
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(.easeInOut(duration: 0.4), value: isFlipped)
        .contentShape(Rectangle())
        .onTapGesture { isFlipped.toggle() }
        .onChange(of: song?.persistentID) { _, _ in
            isFlipped = false
        }
        .task(id: song?.persistentID) {
            await loadArtwork()
        }
        .accessibilityElement()
        .accessibilityLabel(isFlipped ? "Album details" : "Album artwork")
        .accessibilityHint("Double tap to flip")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Front face

    @ViewBuilder
    private var frontFace: some View {
        if let artwork {
            Image(uiImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .brutalistStroke()
        } else {
            ZStack {
                Rectangle().fill(Color.ampNavy)
                if let initial {
                    Text(initial)
                        .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 96))
                        .foregroundStyle(Color.ampWhite)
                }
            }
            .brutalistStroke()
        }
    }

    private var initial: String? {
        guard let title = song?.album ?? song?.title, !title.isEmpty else { return nil }
        return String(title.prefix(1)).uppercased()
    }

    // MARK: - Back face

    private var backFace: some View {
        ZStack {
            Rectangle().fill(Color.ampNavy)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(metadataRows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(row.label)
                            .font(.inversionLabel)
                            .foregroundStyle(Color.ampInversionLabel)
                            .frame(width: 72, alignment: .leading)
                        Text(row.value)
                            .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 13))
                            .foregroundStyle(Color.ampWhite)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
        .brutalistStroke()
    }

    private var metadataRows: [(label: String, value: String)] {
        guard let song else { return [] }
        let rows: [(String, String)] = [
            ("ALBUM", song.album.isEmpty ? "—" : song.album),
            ("YEAR", yearString),
            ("GENRE", (song.genre?.isEmpty == false ? song.genre : nil) ?? "—"),
            ("TRACK", trackString)
        ]
        return rows
    }

    private var yearString: String {
        guard let date = song?.releaseDate else { return "—" }
        return String(Calendar.current.component(.year, from: date))
    }

    // Spec §8.1 asks for "{n} of {m}"; {m} requires an album-side lookup we
    // defer to polish. Showing just the track number here.
    private var trackString: String {
        guard let song, song.albumTrackNumber > 0 else { return "—" }
        return String(song.albumTrackNumber)
    }

    // MARK: - Artwork loading

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
