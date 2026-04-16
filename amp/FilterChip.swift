import SwiftUI

// Spec §5.8: variable width, height 32-36, 4px shadow.
// White + black text (unselected); navy + white text (selected, no shadow).
// Mono bold uppercase label.

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(.custom("AtkinsonHyperlegibleMono-Bold", size: 12))
                .foregroundStyle(isSelected ? Color.ampWhite : Color.ampBlack)
                .animation(.easeInOut(duration: 0.25), value: isSelected)
                .padding(.horizontal, 14)
                .frame(height: 36)
        }
        .buttonStyle(BrutalistInvertibleButtonStyle(isActive: isSelected, offset: .small))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        HStack(spacing: 12) {
            FilterChip(label: "Albums", isSelected: true, action: {})
            FilterChip(label: "Artists", isSelected: false, action: {})
            FilterChip(label: "Playlists", isSelected: false, action: {})
        }
        .padding(24)
    }
}
