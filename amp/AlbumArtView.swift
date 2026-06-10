import SwiftUI
import MediaPlayer

// Spec §8.1 + navigation amendment: front shows the artwork, back shows
// ampNavy metadata as stacked label/value rows — ALBUM, ALBUM ARTIST,
// YEAR, GENRE. Tapping the artwork flips between front and back; tappable
// rows (album, album artist, genre) route to the matching detail via
// NavigationService.push, which targets whichever tab is currently
// selected. Tap on the back-face whitespace (or a non-tappable row like
// YEAR) flips back to the front.
//
// Flip direction is tap-location-aware: a tap on the right half always
// advances the rotation forward (clockwise around Y), a tap on the left
// half always reverses it. flipState accumulates as an integer; parity
// determines which face shows (even = front, odd = back), so right-right
// taps continue spinning forward through full rotations and right-left
// taps short-cycle. The back face is pre-rotated 180° so it reads
// right-side-up at any odd multiple of 180°. Opacity cross-fades the two
// during rotation so text is never mirrored.

struct AlbumArtView: View {
    let song: Song?

    @ObservedObject private var nav = NavigationService.shared
    @State private var flipState: Int = 0
    @State private var artwork: UIImage?
    @State private var albumArtist: String?

    private var isFlipped: Bool { flipState % 2 != 0 }
    private var rotationAngle: Double { Double(flipState) * 180 }

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
        .clipped()
        .rotation3DEffect(.degrees(rotationAngle), axis: (x: 0, y: 1, z: 0))
        .animation(.easeInOut(duration: 0.4), value: flipState)
        .onChange(of: song?.persistentID) { _, _ in
            flipState = 0
        }
        .task(id: song?.persistentID) {
            await loadMetadata()
        }
        .accessibilityElement()
        .accessibilityLabel(isFlipped ? "Album details" : "Album artwork")
        .accessibilityHint(isFlipped ? "Double tap a row to navigate" : "Double tap to flip")
        .accessibilityAddTraits(.isButton)
    }

    // Right half → +1 (forward spin), left half → -1 (reverse spin).
    // Either way parity flips, so the opposite face becomes visible.
    private func flip(tappedAt location: CGPoint, width: CGFloat) {
        if location.x >= width / 2 {
            flipState += 1
        } else {
            flipState -= 1
        }
    }

    // MARK: - Front face

    @ViewBuilder
    private var frontFace: some View {
        GeometryReader { geo in
            Group {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ZStack {
                        Rectangle().fill(Color.ampNavy)
                        if let initial {
                            Text(initial)
                                .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 116))
                                .foregroundStyle(Color.ampWhite)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .brutalistStroke()
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { event in
                        flip(tappedAt: event.location, width: geo.size.width)
                    }
            )
        }
    }

    private var initial: String? {
        guard let title = song?.album ?? song?.title, !title.isEmpty else { return nil }
        return String(title.prefix(1)).uppercased()
    }

    // MARK: - Back face

    private var backFace: some View {
        GeometryReader { geo in
            ZStack {
                // Tapping the navy background (anywhere not on a link or label
                // text) flips back to the artwork. Direction depends on which
                // half was tapped.
                Rectangle()
                    .fill(Color.ampNavy)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { event in
                                flip(tappedAt: event.location, width: geo.size.width)
                            }
                    )

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
            .frame(width: geo.size.width, height: geo.size.height)
            .brutalistStroke()
        }
    }

    // MARK: - Metadata model

    fileprivate struct Row: Equatable {
        enum Kind: Equatable { case album, artist, year, genre }
        let label: String
        let value: String
        let kind: Kind
        var isTappable: Bool {
            switch kind {
            case .album, .artist, .genre: true
            case .year: false
            }
        }
    }

    private var metadataRows: [Row] {
        guard let song else { return [] }
        return [
            Row(label: "ALBUM", value: song.album.isEmpty ? "—" : song.album, kind: .album),
            Row(label: "ALBUM ARTIST", value: albumArtistString, kind: .artist),
            Row(label: "YEAR", value: yearString, kind: .year),
            Row(label: "GENRE", value: (song.genre?.isEmpty == false ? song.genre : nil) ?? "—", kind: .genre)
        ]
    }

    private var yearString: String {
        guard let date = song?.releaseDate else { return "—" }
        return String(Calendar.current.component(.year, from: date))
    }

    // Prefer the MPMediaItem albumArtist (loaded async); fall back to the
    // track artist on the Song so the row is never blank while loading.
    private var albumArtistString: String {
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        if let song, !song.artist.isEmpty { return song.artist }
        return "—"
    }

    // MARK: - Taps

    private func handleTap(_ row: Row) {
        switch row.kind {
        case .album:
            navigateToAlbum()
        case .artist:
            navigateToArtist()
        case .genre:
            navigateToGenre(row.value)
        case .year:
            // Not navigable — non-tappable rows shouldn't receive taps
            // (their text is hit-disabled), but keep this no-op safe.
            break
        }
    }

    // Navigating away resets the flip so the artwork shows on return.
    // Snapping flipState back to 0 is fine because the view disappears
    // during navigation — no animation jump is visible.
    private func navigateToArtist() {
        guard let song else { return }
        flipState = 0
        nav.navigateToArtist(forTrack: song.persistentID)
    }

    private func navigateToAlbum() {
        guard let song else { return }
        flipState = 0
        nav.navigateToAlbum(forTrack: song.persistentID)
    }

    private func navigateToGenre(_ genre: String) {
        flipState = 0
        nav.navigateToGenre(genre)
    }

    // MARK: - Loading

    // One MPMediaQuery by track ID returns both the albumPersistentID and
    // the albumArtist; artwork then goes through ArtworkCache keyed by
    // albumID, so skipping to another track on the same album (or viewing
    // the same album next session, via the disk thumbnail cache) is a hit.
    // Replaces an older split-loader that ran two identical queries.
    private func loadMetadata() async {
        guard let song else {
            artwork = nil
            albumArtist = nil
            return
        }
        let id = song.persistentID

        let result = await Task.detached(priority: .userInitiated) { () -> (albumID: MPMediaEntityPersistentID, albumArtist: String?)? in
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: id),
                forProperty: MPMediaItemPropertyPersistentID
            )
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(predicate)
            guard let item = query.items?.first else { return nil }
            return (item.albumPersistentID, item.albumArtist ?? item.artist)
        }.value

        albumArtist = result?.albumArtist

        if let albumID = result?.albumID {
            artwork = await ArtworkCache.shared.artwork(
                forAlbum: albumID,
                size: CGSize(width: 800, height: 800)
            )
        } else {
            artwork = nil
        }
    }
}

// MARK: - MetadataRow

// Tap target on tappable rows is restricted to the value text only —
// label, surrounding whitespace, and non-tappable rows (YEAR) let the
// tap fall through to the parent's navy rectangle, which handles the
// flip-back with direction awareness. `allowsHitTesting(false)` on the
// non-link content is what makes that fall-through work.
private struct MetadataRow: View {
    let row: AlbumArtView.Row
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.label)
                .font(.inversionLabel)
                .foregroundStyle(Color.ampInversionLabel)
                .allowsHitTesting(false)

            valueText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isTappable ? .isButton : [])
    }

    @ViewBuilder
    private var valueText: some View {
        let text = Text(row.value)
            .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 26))
            .foregroundStyle(Color.ampWhite)
            .underline(row.isTappable, color: Color.ampInversionLabel)
            .lineLimit(2)
            .multilineTextAlignment(.leading)

        if row.isTappable {
            // Wrap in an HStack with a trailing Spacer so the Text takes
            // only its rendered width; the tap target then matches the
            // underlined link, not the full row width.
            HStack(spacing: 0) {
                text
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
            }
        } else {
            text.allowsHitTesting(false)
        }
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
