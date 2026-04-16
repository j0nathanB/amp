import SwiftUI

// Spec §5.5: 60 tall. Title at x=24, subtitle {Artist} · <italic>{Album}</italic>,
// duration right-aligned. 1px divider at bottom.
//
// Uses .onTapGesture + .contentShape instead of Button so the outer frame
// stays authoritative for LazyVStack sizing (see ArtistRow for background).

struct SongResultRow: View {
    let title: String
    let artist: String
    let album: String
    let duration: String
    let onTap: () -> Void
    let onLongPress: (() -> Void)?

    init(
        title: String,
        artist: String,
        album: String,
        duration: String,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.listTitle)
                    .foregroundStyle(Color.ampBlack)
                    .lineLimit(1)
                subtitle
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
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ampDivider)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
        .onTapGesture(perform: onTap)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                onLongPress?()
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) by \(artist) from \(album), \(duration)")
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: some View {
        HStack(spacing: 6) {
            Text(artist)
                .font(.subtitle)
                .foregroundStyle(Color.ampMutedText)
            Text("·")
                .font(.subtitle)
                .foregroundStyle(Color.ampMutedText)
            Text(album)
                .font(.subtitleItalic)
                .foregroundStyle(Color.ampMutedText)
        }
        .lineLimit(1)
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
