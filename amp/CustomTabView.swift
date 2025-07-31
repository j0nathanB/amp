import SwiftUI

struct CustomTabView: View {
    @Binding var selectedTab: Tab

    var body: some View {
        HStack(spacing: -1) {
            // The unused 'icon' parameter has been removed
            TabButton(title: "Playlists", isSelected: selectedTab == .playlists) {
                selectedTab = .playlists
            }
            
            TabButton(title: "Queue", isSelected: selectedTab == .queue) {
                selectedTab = .queue
            }
            
            TabButton(title: "Search", isSelected: selectedTab == .search) {
                selectedTab = .search
            }
            
            TabButton(title: "Playing", isSelected: selectedTab == .nowPlaying) {
                selectedTab = .nowPlaying
            }
        }
        .frame(width: UIScreen.main.bounds.width, height: 80) // Fixed width to screen width
        .padding(.bottom, 34) // Fixed bottom padding instead of system default
        .background(.white) // Ensure the container has a background
        .overlay(Divider(), alignment: .top)
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
            // Layer 1: The background color
            Rectangle()
                .fill(isSelected ? Theme.accentPink : .white)

            // Layer 2: The text content
            Text(title)
                .font(isSelected ? Theme.tabFontSelected : Theme.tabFont)
                .foregroundColor(isSelected ? .white : Theme.primaryText)
        }
        .contentShape(Rectangle()) // Makes the entire ZStack area tappable
        .onTapGesture(perform: action) // Use a tap gesture instead of a Button
        .border(Theme.primaryText, width: 1)
    }
}
