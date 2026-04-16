import SwiftUI

// Spec §5.11: white fill, 4px shadow, 2px stroke, height 44.
// Icon = 3 stacked black lines (14, 20, 12 px long) + "Lyrics" label in .listTitle.
// Shown when Settings.showLyricsButton == true (default on). When hidden, Like centers.

struct LyricsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LyricsGlyph()
                    .frame(width: 20, height: 12)
                Text("Lyrics")
                    .font(.listTitle)
                    .foregroundStyle(Color.ampBlack)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color.ampWhite)
            .brutalistStroke()
            .brutalistShadow(.small)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Lyrics")
    }
}

private struct LyricsGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(Color.ampBlack).frame(width: 14, height: 2)
            Rectangle().fill(Color.ampBlack).frame(width: 20, height: 2)
            Rectangle().fill(Color.ampBlack).frame(width: 12, height: 2)
        }
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        LyricsButton(action: {})
    }
}
