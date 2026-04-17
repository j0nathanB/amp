import SwiftUI

// Spec §5.15: 44×44, 4px shadow, 2px stroke.
// Unliked: white fill, black heart outline. Liked: navy fill, white solid heart, no shadow.

struct LikeButton: View {
    let isLiked: Bool
    let trackTitle: String
    let onTap: () -> Void

    // Liked state keeps the white button background — only the heart
    // glyph changes: red fill (#DB0000) and a larger point size so the
    // heart reads as "more" inside the unchanged 44×44 bounding box.
    private static let likedRed = Color(red: 0xDB / 255, green: 0, blue: 0)

    var body: some View {
        Button(action: onTap) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: isLiked ? 26 : 18, weight: .semibold))
                .foregroundStyle(isLiked ? Self.likedRed : Color.ampBlack)
                // .identity makes the symbol swap instantaneous so the
                // fill → outline happens in a single frame. Without this,
                // SwiftUI's default symbol-replace crossfade left a big
                // red-fading-to-black filled heart visible mid-transition
                // — reading as a "big navy heart". Size animates smoothly
                // via the .animation below.
                .contentTransition(.identity)
                .animation(.easeInOut(duration: 0.25), value: isLiked)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(BrutalistButtonStyle(offset: .small, fillColor: .ampWhite))
        .accessibilityLabel(isLiked ? "Unlike \(trackTitle)" : "Like \(trackTitle)")
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        HStack(spacing: 16) {
            LikeButton(isLiked: false, trackTitle: "Idioteque", onTap: {})
            LikeButton(isLiked: true, trackTitle: "Idioteque", onTap: {})
        }
    }
}
