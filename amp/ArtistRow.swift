import SwiftUI

// Spec §5.7: 48 tall. Name at x=24 .listTitle, meta right-aligned
// `.metadata muted "{N} albums"`. 1px divider at bottom.

struct ArtistRow: View {
    let name: String
    let albumCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Text(name)
                    .font(.listTitle)
                    .foregroundStyle(Color.ampBlack)
                    .lineLimit(1)
                    .padding(.leading, 24)
                Spacer(minLength: 12)
                Text("\(albumCount) \(albumCount == 1 ? "album" : "albums")")
                    .font(.metadata)
                    .foregroundStyle(Color.ampMutedText)
                    .padding(.trailing, 24)
            }
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.ampDivider)
                    .frame(height: 1)
                    .padding(.horizontal, 24)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(albumCount) albums")
    }
}

#Preview {
    ZStack {
        Color.ampWhite.ignoresSafeArea()
        VStack(spacing: 0) {
            ArtistRow(name: "Radiohead", albumCount: 9, onTap: {})
            ArtistRow(name: "Deftones", albumCount: 10, onTap: {})
            ArtistRow(name: "Björk", albumCount: 14, onTap: {})
        }
    }
}
