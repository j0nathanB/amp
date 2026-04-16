import SwiftUI
import MediaPlayer

// Typed routes pushed onto per-tab NavigationStacks. Each case carries the
// minimum data the destination needs to fetch its content from services.
// Spec §7.4–§7.9 list the pushable destinations; all placeholder for Phase C
// and replaced by real views in Phase D/E/F.

enum AmpRoute: Hashable {
    case albumDetail(MPMediaEntityPersistentID)
    case artistDetail(MPMediaEntityPersistentID)
    case playlistDetail(MPMediaEntityPersistentID)
    case settings
    case lyrics
}

// Destination dispatcher. Pushes to real views when they exist; otherwise
// renders a placeholder until the corresponding phase replaces it.
struct AmpRouteDestination: View {
    let route: AmpRoute

    var body: some View {
        switch route {
        case .settings:
            SettingsView()
        case .lyrics:
            LyricsView()
        case .albumDetail, .artistDetail, .playlistDetail:
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Text(placeholderTitle)
                .font(.viewTitle)
                .foregroundStyle(Color.ampBlack)
            Text("Coming in a later phase.")
                .font(.metadata)
                .foregroundStyle(Color.ampMutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var placeholderTitle: String {
        switch route {
        case .albumDetail: "Album Detail"
        case .artistDetail: "Artist Detail"
        case .playlistDetail: "Playlist Detail"
        case .settings: "Settings"
        case .lyrics: "Lyrics"
        }
    }
}
