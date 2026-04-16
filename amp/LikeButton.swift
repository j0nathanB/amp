import SwiftUI

// Spec §5.15: 44×44, 4px shadow, 2px stroke.
// Unliked: white fill, black heart outline. Liked: navy fill, white solid heart, no shadow.

struct LikeButton: View {
    let isLiked: Bool
    let trackTitle: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isLiked ? Color.ampWhite : Color.ampBlack)
                .animation(.easeInOut(duration: 0.25), value: isLiked)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(BrutalistInvertibleButtonStyle(isActive: isLiked, offset: .small))
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
