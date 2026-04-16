import SwiftUI
import MediaPlayer

// Typed routes pushed onto per-tab NavigationStacks. Each case carries the
// minimum data the destination needs to fetch its content from services.

enum AmpRoute: Hashable {
    case albumDetail(MPMediaEntityPersistentID)
    case artistDetail(MPMediaEntityPersistentID)
    case playlistDetail(MPMediaEntityPersistentID)
    case settings
    case lyrics
}

// Dispatcher: each case maps to its real destination view. No more
// placeholders — all detail views landed in Phase H.
struct AmpRouteDestination: View {
    let route: AmpRoute

    var body: some View {
        switch route {
        case .albumDetail(let id):
            AlbumDetailView(albumID: id)
        case .artistDetail(let id):
            ArtistDetailView(artistID: id)
        case .playlistDetail(let id):
            PlaylistDetailView(playlistID: id)
        case .settings:
            SettingsView()
        case .lyrics:
            LyricsView()
        }
    }
}
