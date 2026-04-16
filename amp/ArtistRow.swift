import SwiftUI

// Spec §5.7: 48 tall. Name at x=24 .listTitle, meta right-aligned
// `.metadata muted "{N} albums"`. 1px divider at bottom.
//
// Uses .onTapGesture + .contentShape instead of Button so the outer frame
// stays authoritative for LazyVStack sizing — a Button's internal layout
// can cause occasional double-height / ghost-row glitches when rows are
// recycled during scroll.

struct ArtistRow: View {
    let name: String
    let albumCount: Int
    let onTap: () -> Void

    var body: some View {
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
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ampDivider)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(albumCount) albums")
        .accessibilityAddTraits(.isButton)
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
