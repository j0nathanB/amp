import SwiftUI

// Spec §5.5: 60 tall. Title at x=24, subtitle {Artist} · <italic>{Album}</italic>,
// duration right-aligned. 1px divider at bottom.
//
// `isCurrent` flips the row to a navy-inverted variant — white text on
// navy, no decoration. Used by ArtistDetailView so the currently playing
// song highlights the same way Album / Playlist Detail do via TrackRow.
// Library songs list and Search results pass the defaults and render
// unchanged.
//
// Uses .onTapGesture + .contentShape instead of Button so the outer frame
// stays authoritative for LazyVStack sizing (see ArtistRow for background).

struct SongResultRow: View {
    let title: String
    let artist: String
    let album: String
    let duration: String
    let isCurrent: Bool
    let onTap: () -> Void
    let onLongPress: (() -> Void)?

    init(
        title: String,
        artist: String,
        album: String,
        duration: String,
        isCurrent: Bool = false,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.isCurrent = isCurrent
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    var body: some View {
        Group {
            if isCurrent { navyInverted } else { regular }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                onLongPress?()
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits([.isButton, isCurrent ? .isSelected : []])
    }

    // MARK: - Regular variant

    private var regular: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.listTitle)
                    .foregroundStyle(Color.ampBlack)
                    .lineLimit(1)
                subtitle(artistColor: Color.ampMutedText, albumColor: Color.ampMutedText)
            }
            .padding(.leading, 24)
            Spacer(minLength: 12)
            Text(duration)
                .font(.timestamp)
                .foregroundStyle(Color.ampMutedText)
                .padding(.trailing, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ampDivider)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Navy-inverted variant (current track)
    //
    // Navy inversion alone marks the current track — no equalizer bars.
    // Title starts at x=24 (same gutter as the regular variant) so rows
    // don't reshape when they become current.

    private var navyInverted: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.listTitle)
                    .foregroundStyle(Color.ampWhite)
                    .lineLimit(1)
                subtitle(artistColor: Color.ampInversionLabel, albumColor: Color.ampInversionLabel)
            }
            .padding(.leading, 24)

            Spacer(minLength: 12)
            Text(duration)
                .font(.timestamp)
                .foregroundStyle(Color.ampWhite)
                .padding(.trailing, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
        .background(Color.ampNavy)
    }

    // MARK: - Shared pieces

    @ViewBuilder
    private func subtitle(artistColor: Color, albumColor: Color) -> some View {
        HStack(spacing: 6) {
            Text(artist)
                .font(.subtitle)
                .foregroundStyle(artistColor)
            Text("·")
                .font(.subtitle)
                .foregroundStyle(artistColor)
            Text(album)
                .font(.subtitleItalic)
                .foregroundStyle(albumColor)
        }
        .lineLimit(1)
    }

    private var a11yLabel: String {
        let base = "\(title) by \(artist) from \(album), \(duration)"
        return isCurrent ? "Now playing: \(base)" : base
    }
}

#Preview {
    ZStack {
        Color.ampWhite.ignoresSafeArea()
        VStack(spacing: 0) {
            SongResultRow(title: "Idioteque", artist: "Radiohead", album: "Kid A", duration: "5:09", onTap: {})
            SongResultRow(title: "My Own Summer", artist: "Deftones", album: "Around the Fur", duration: "3:34", onTap: {})
        }
    }
}
