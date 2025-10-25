import SwiftUI

struct CustomTabView: View {
    @Binding var selectedTab: Tab

    var body: some View {
        HStack(spacing: 8) {
            TabButton(title: "Mixes", isSelected: selectedTab == .playlists) {
                selectedTab = .playlists
            }

            TabButton(title: "Queue", isSelected: selectedTab == .queue) {
                selectedTab = .queue
            }

            TabButton(title: "Search", isSelected: selectedTab == .search) {
                selectedTab = .search
            }

            TabButton(title: "Active", isSelected: selectedTab == .nowPlaying) {
                selectedTab = .nowPlaying
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 82)
        .frame(maxWidth: .infinity)
        .background(.white)
        .overlay(Divider(), alignment: .top)
        .edgesIgnoringSafeArea(.bottom)
    }
}

private struct TabButton: View {
    let title: String
    // The unused 'icon' property has been removed
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        // Using a ZStack gives us more control over rendering and animation
        ZStack {
            // Layer 1: The hard shadow (offset background)
            Capsule()
                .fill(Theme.accentBlue)
                .offset(x: -6, y: 6)

            // Layer 2: The main button background
            Capsule()
                .fill(isSelected ? Theme.accentLightBlue : .white)

            // Layer 3: The text content
            Text(title)
                .font(Theme.tabFont)
                .foregroundColor(Theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .contentShape(Capsule()) // Makes the entire capsule area tappable
        .onTapGesture(perform: action) // Use a tap gesture instead of a Button
        .overlay(
            Capsule()
                .stroke(Theme.primaryText, lineWidth: 2)
        )
    }
}
