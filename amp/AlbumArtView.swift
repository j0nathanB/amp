import SwiftUI
import MediaPlayer

// Spec §8.1 + navigation amendment: front shows the artwork, back shows
// metadata on a gray (ampMutedText) card as centered, label-less lines —
// song, artist, album, year, then a wrapping row of genre links. Tapping
// the artwork flips between front and back; tappable lines (artist, album,
// each genre) route to the matching detail via NavigationService.push,
// which targets whichever tab is currently selected. Tap on the back-face
// whitespace (or a non-tappable line like song/year) flips back to the front.
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
        .onChange(of: song?.persistentID) { _, _ in
            // Snap the new track to its front face *without* animating. The
            // flip is explicitly animated in flip(); an implicit
            // .animation(value: flipState) here would instead animate this
            // reset, rewinding the accumulated rotation (e.g. 3 → 0 = a 540°
            // spin) every time the track changes while the card was flipped.
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
        withAnimation(.easeInOut(duration: 0.4)) {
            if location.x >= width / 2 {
                flipState += 1
            } else {
                flipState -= 1
            }
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
                // Tapping the gray background (anywhere not on a link) flips
                // back to the artwork. Direction depends on which half was
                // tapped.
                Rectangle()
                    .fill(Color.ampMutedText)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { event in
                                flip(tappedAt: event.location, width: geo.size.width)
                            }
                    )

                VStack(alignment: .center, spacing: 16) {
                    ForEach(metadataRows, id: \.label) { row in
                        MetadataRow(row: row) {
                            handleTap(row)
                        }
                    }
                    if !genres.isEmpty {
                        GenreRow(genres: genres) { navigateToGenre($0) }
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
        enum Kind: Equatable { case song, artist, album, year }
        let label: String
        let value: String
        let kind: Kind
        var isTappable: Bool {
            switch kind {
            case .artist, .album: true
            case .song, .year: false
            }
        }
    }

    // Order: song, artist, album, year (genres render below as their own
    // wrapping block). Labels are intentionally omitted and the values are
    // centered, so a field with no value would show as a bare, meaningless
    // line — those are dropped entirely, same spirit as the empty-genre case.
    private var metadataRows: [Row] {
        guard let song else { return [] }
        var rows: [Row] = []
        if !song.title.isEmpty {
            rows.append(Row(label: "SONG", value: song.title, kind: .song))
        }
        let artist = albumArtistString
        if !artist.isEmpty {
            rows.append(Row(label: "ARTIST", value: artist, kind: .artist))
        }
        if !song.album.isEmpty {
            rows.append(Row(label: "ALBUM", value: song.album, kind: .album))
        }
        if let year = yearString {
            rows.append(Row(label: "YEAR", value: year, kind: .year))
        }
        return rows
    }

    // A single tag may split into several independently-clickable components
    // ("Classic Rock/Rock" → "Classic Rock", "Rock"); the whole block is
    // omitted when the track has no genre.
    private var genres: [String] {
        song?.genre?.genreComponents ?? []
    }

    private var yearString: String? {
        guard let date = song?.releaseDate else { return nil }
        return String(Calendar.current.component(.year, from: date))
    }

    // Prefer the MPMediaItem albumArtist (loaded async); fall back to the
    // track artist on the Song. Empty when neither is known, so the row drops.
    private var albumArtistString: String {
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        if let song, !song.artist.isEmpty { return song.artist }
        return ""
    }

    // MARK: - Taps

    private func handleTap(_ row: Row) {
        switch row.kind {
        case .artist:
            navigateToArtist()
        case .album:
            navigateToAlbum()
        case .song, .year:
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

    // One source lookup by track ID returns both the album id and the
    // albumArtist (via the LibrarySource seam — MP query in music mode,
    // catalog read in folder mode); artwork then goes through ArtworkCache
    // keyed by albumID, so skipping to another track on the same album (or
    // viewing the same album next session, via the disk thumbnail cache)
    // is a hit.
    private func loadMetadata() async {
        guard let song else {
            artwork = nil
            albumArtist = nil
            return
        }
        let id = song.persistentID

        let result = await Task.detached(priority: .userInitiated) {
            LibraryService.shared.getTrackAlbumInfo(forTrack: id)
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

// A single centered value line (labels were dropped from the card). On
// tappable rows the tap target is restricted to the value text itself —
// flanking whitespace and non-tappable rows (SONG, YEAR) let the tap fall
// through to the parent's gray rectangle, which handles the flip-back with
// direction awareness. `allowsHitTesting(false)` on the flanks and on
// non-link text is what makes that fall-through work.
private struct MetadataRow: View {
    let row: AlbumArtView.Row
    let onTap: () -> Void

    var body: some View {
        let text = Text(row.value)
            .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 22))
            .foregroundStyle(Color.ampWhite)
            .underline(row.isTappable, color: Color.ampWhite)
            .lineLimit(2)
            .multilineTextAlignment(.center)

        if row.isTappable {
            // Spacers on both sides keep the Text at its rendered width and
            // centered, so the tap target matches the underlined link and the
            // background beside it still flips the card.
            HStack(spacing: 0) {
                Spacer(minLength: 0).allowsHitTesting(false)
                text
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                Spacer(minLength: 0).allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement()
            .accessibilityLabel(row.value)
            .accessibilityAddTraits(.isButton)
        } else {
            text
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .accessibilityLabel(row.value)
        }
    }
}

// MARK: - GenreRow
//
// A centered, wrapping run of independently-tappable genre links (one per
// split component). Each routes to its own Genre Detail. Matches the
// MetadataRow link treatment (bold 22, white, white underline); the tap
// target is restricted to each underlined word so the gray background between
// them still flips the card back.
private struct GenreRow: View {
    let genres: [String]
    let onTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 14, rowSpacing: 6) {
            ForEach(Array(genres.enumerated()), id: \.offset) { _, genre in
                Text(genre)
                    .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 22))
                    .foregroundStyle(Color.ampWhite)
                    .underline(true, color: Color.ampWhite)
                    .fixedSize()
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(genre) }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - FlowLayout
//
// Minimal wrapping layout that packs subviews into rows (wrapping when the
// next would overflow the proposed width) and centers each row horizontally.
// Used for the genre links, which can be several short words on a narrow
// (square-artwork) card and should read centered with the rest of the info.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 14
    var rowSpacing: CGFloat = 6

    // Group subview indices into rows for a given width. Each row also carries
    // its packed width and tallest height so both passes agree on layout.
    private struct RowInfo { var indices: [Int]; var width: CGFloat; var height: CGFloat }

    private func rows(subviews: Subviews, maxWidth: CGFloat) -> [RowInfo] {
        var rows: [RowInfo] = []
        var current = RowInfo(indices: [], width: 0, height: 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = current.indices.isEmpty ? size.width : spacing + size.width
            if !current.indices.isEmpty, current.width + advance > maxWidth {
                rows.append(current)
                current = RowInfo(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width += advance
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(subviews: subviews, maxWidth: maxWidth)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
            + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
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
