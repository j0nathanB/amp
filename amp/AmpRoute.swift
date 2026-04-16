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

// Placeholder destination view. Phase D/E/F will replace each arm with the real view.
struct AmpRouteDestination: View {
    let route: AmpRoute

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
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

    private var title: String {
        switch route {
        case .albumDetail: "Album Detail"
        case .artistDetail: "Artist Detail"
        case .playlistDetail: "Playlist Detail"
        case .settings: "Settings"
        case .lyrics: "Lyrics"
        }
    }
}
