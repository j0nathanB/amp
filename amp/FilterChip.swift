import SwiftUI

// Spec §5.8 + amendment: inactive chips render an SF Symbol (compact);
// active chip expands to show the uppercase text label. Width changes
// on toggle — HStack in Library reflows around it.
// White + 2px stroke + 4px navy shadow when inactive; navy inversion
// when active (no shadow). Press feedback via BrutalistInvertibleButtonStyle.

struct FilterChip: View {
    let label: String
    let systemIcon: String?
    let isSelected: Bool
    let action: () -> Void

    init(
        label: String,
        systemIcon: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemIcon = systemIcon
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 14)
                .frame(height: 36)
        }
        .buttonStyle(BrutalistInvertibleButtonStyle(isActive: isSelected, offset: .small))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        if isSelected || systemIcon == nil {
            Text(label.uppercased())
                .font(.custom("AtkinsonHyperlegibleMono-Bold", size: 15))
                .foregroundStyle(isSelected ? Color.ampWhite : Color.ampBlack)
        } else if let systemIcon {
            Image(systemName: systemIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.ampBlack)
        }
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        HStack(spacing: 12) {
            FilterChip(label: "Albums", systemIcon: "record.circle.fill", isSelected: true, action: {})
            FilterChip(label: "Artists", systemIcon: "person.fill", isSelected: false, action: {})
            FilterChip(label: "Songs", systemIcon: "music.pages", isSelected: false, action: {})
            FilterChip(label: "Playlists", systemIcon: "music.note.list", isSelected: false, action: {})
        }
        .padding(24)
    }
}
