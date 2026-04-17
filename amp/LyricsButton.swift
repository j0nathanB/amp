import SwiftUI

// Spec §5.11: white fill, 4px shadow, 2px stroke, height 44.
// Icon = 3 stacked black lines (14, 20, 12 px long) + "Lyrics" label in .listTitle.
// Shown when Settings.showLyricsButton == true (default on). When hidden, Like centers.

struct LyricsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "music.note.list")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.ampBlack)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(BrutalistButtonStyle(offset: .small, fillColor: .ampWhite))
        .accessibilityLabel("Lyrics")
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        LyricsButton(action: {})
    }
}
