import SwiftUI
import MediaPlayer

// Typed routes pushed onto per-tab NavigationStacks. Each case carries the
// minimum data the destination needs to fetch its content from services.

enum AmpRoute: Hashable {
    case albumDetail(MPMediaEntityPersistentID)
    case artistDetail(MPMediaEntityPersistentID)
    case playlistDetail(MPMediaEntityPersistentID)
    case genreDetail(String)
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
        case .genreDetail(let name):
            GenreDetailView(genre: name)
        case .settings:
            SettingsView()
        case .lyrics:
            LyricsView()
        }
    }
}

// Placeholder. Real GenreDetail will list songs/albums in the genre —
// wire up once we decide whether to lean on LibraryService.searchByGenre
// or add a dedicated getGenres/getSongs(forGenre:) helper.
struct GenreDetailView: View {
    let genre: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                BackButton { dismiss() }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            ViewTitleBlock("Genre")
                .padding(.horizontal, 24)

            Text(genre)
                .font(.nowPlayingTitle)
                .foregroundStyle(Color.ampBlack)
                .padding(.top, 12)

            Text("Genre detail — coming soon.")
                .font(.metadata)
                .foregroundStyle(Color.ampMutedText)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
    }
}
