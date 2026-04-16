import SwiftUI

// Spec §5.6: 80 tall. 64×64 thumbnail at x=24, 4px navy shadow, 2px stroke.
// Fallback: solid ampNavy block with first letter in white sans bold.
// Title + meta (year · track count tracks) to the right of the thumbnail.

struct AlbumRow: View {
    let artwork: UIImage?
    let title: String
    let year: Int?
    let trackCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                thumbnail
                    .padding(.leading, 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.listTitle)
                        .foregroundStyle(Color.ampBlack)
                        .lineLimit(1)
                    Text(metaLine)
                        .font(.metadata)
                        .foregroundStyle(Color.ampMutedText)
                }
                .padding(.leading, 16)
                Spacer(minLength: 12)
            }
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.ampDivider)
                    .frame(height: 1)
                    .padding(.horizontal, 24)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(metaLine)")
    }

    private var metaLine: String {
        if let year {
            return "\(year)  ·  \(trackCount) tracks"
        }
        return "\(trackCount) tracks"
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let artwork {
            Image(uiImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipped()
                .brutalistStroke()
                .brutalistShadow(.small)
        } else {
            Text(String(title.prefix(1)).uppercased())
                .font(.custom("AtkinsonHyperlegibleNext-Bold", size: 28))
                .foregroundStyle(Color.ampWhite)
                .frame(width: 64, height: 64)
                .background(Color.ampNavy)
                .brutalistStroke()
                .brutalistShadow(.small)
        }
    }
}

#Preview {
    ZStack {
        Color.ampWhite.ignoresSafeArea()
        VStack(spacing: 0) {
            AlbumRow(artwork: nil, title: "Kid A", year: 2000, trackCount: 10, onTap: {})
            AlbumRow(artwork: nil, title: "OK Computer", year: 1997, trackCount: 12, onTap: {})
            AlbumRow(artwork: nil, title: "In Rainbows", year: 2007, trackCount: 10, onTap: {})
        }
    }
}
