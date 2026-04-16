import SwiftUI

// Spec §5.9 + amendment: icon-only tabs (labels dropped). 72×56 brutalist
// primitive, SF Symbol centered. Press feedback + active inversion come
// from BrutalistInvertibleButtonStyle.
// AmpTab itself lives in DataModels.swift.

struct TabBarTab: View {
    let tab: AmpTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.systemIcon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isSelected ? Color.ampWhite : Color.ampBlack)
                .animation(.easeInOut(duration: 0.25), value: isSelected)
                .frame(width: 72, height: 56)
        }
        .buttonStyle(BrutalistInvertibleButtonStyle(isActive: isSelected, offset: .small))
        .accessibilityLabel(tab.rawValue.capitalized)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension AmpTab {
    var systemIcon: String {
        switch self {
        case .library: "line.3.horizontal"
        case .search: "magnifyingglass"
        case .queue: "list.bullet"
        case .active: "playpause.fill"
        }
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        HStack(spacing: 8) {
            TabBarTab(tab: .library, isSelected: true, action: {})
            TabBarTab(tab: .search, isSelected: false, action: {})
            TabBarTab(tab: .queue, isSelected: false, action: {})
            TabBarTab(tab: .active, isSelected: false, action: {})
        }
    }
}
