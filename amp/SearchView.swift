import SwiftUI
import MediaPlayer

// Spec §7.2: Search tab root. SearchInput at top. Three content states:
//
// 1. Empty (no text, no recents)  → "Search your library."
// 2. Empty (no text, has recents) → yellow RECENT block + recent rows +
//                                    CLEAR RECENT text link
// 3. Query typed                  → Results grouped into yellow
//                                    Artists / Albums / Songs blocks, or
//                                    "No results found." when empty
//
// Taps: artist → push ArtistDetail, album → push AlbumDetail, song →
// start playback of the song list (spec §8.2). Recents are written on
// result tap (deliberate search) rather than on every keystroke so typos
// and abandoned queries don't pollute history.

struct SearchView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var nav = NavigationService.shared
    @ObservedObject private var vm = SearchViewModel.shared
    @ObservedObject private var recents = RecentSearchesService.shared

    var body: some View {
        VStack(spacing: 0) {
            SearchInput(text: $vm.searchText)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .onChange(of: vm.searchText) { _, _ in
                    vm.performSearch()
                }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        let query = vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            if recents.recents.isEmpty {
                centeredHint("Search your library.")
            } else {
                recentsView
            }
        } else {
            resultsView
        }
    }

    private func centeredHint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.metadata)
                .foregroundStyle(Color.ampMutedText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Recents view

    private var recentsView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ViewTitleBlock("RECENT")
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                VStack(spacing: 0) {
                    ForEach(Array(recents.recents.enumerated()), id: \.offset) { _, q in
                        RecentRow(query: q) {
                            vm.searchText = q
                            vm.performSearch()
                        }
                    }
                }
                .padding(.bottom, 4)

                TextLink(label: "Clear Recent") {
                    recents.clearAll()
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Results view

    @ViewBuilder
    private var resultsView: some View {
        let results = vm.searchResults
        let hasAny = !results.artists.isEmpty
            || !results.albums.isEmpty
            || !results.songs.isEmpty
        if !hasAny {
            centeredHint(vm.isSearching ? "Searching…" : "No results found.")
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if !results.artists.isEmpty {
                        sectionHeader("Artists")
                        VStack(spacing: 0) {
                            ForEach(results.artists) { artist in
                                SearchArtistRow(name: artist.name) {
                                    recordRecent()
                                    nav.push(.artistDetail(artist.id))
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }

                    if !results.albums.isEmpty {
                        sectionHeader("Albums")
                        VStack(spacing: 0) {
                            ForEach(results.albums) { album in
                                SearchAlbumRow(title: album.title, artist: album.artist) {
                                    recordRecent()
                                    nav.push(.albumDetail(album.id))
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }

                    if !results.songs.isEmpty {
                        sectionHeader("Songs")
                        VStack(spacing: 0) {
                            ForEach(Array(results.songs.enumerated()), id: \.offset) { index, song in
                                SongResultRow(
                                    title: song.title,
                                    artist: song.artist,
                                    album: song.album,
                                    duration: "",
                                    onTap: {
                                        recordRecent()
                                        let ids = results.songs.map { $0.persistentID }
                                        audioPlayer.startPlayback(fromTrackIDs: ids, startingAt: index)
                                    },
                                    onLongPress: {
                                        nav.navigateToAlbum(forTrack: song.persistentID)
                                    }
                                )
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        ViewTitleBlock(title)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
    }

    private func recordRecent() {
        recents.addRecent(vm.searchText)
    }
}

// MARK: - Row primitives (§7.2 shapes — kept narrow for Search's needs)

private struct RecentRow: View {
    let query: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(query)
                .font(.listTitle)
                .foregroundStyle(Color.ampBlack)
                .lineLimit(1)
                .padding(.leading, 24)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .center)
        .background(Color.ampWhite)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ampDivider)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel("Recent search: \(query)")
        .accessibilityAddTraits(.isButton)
    }
}

private struct SearchArtistRow: View {
    let name: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(name)
                .font(.listTitle)
                .foregroundStyle(Color.ampBlack)
                .lineLimit(1)
                .padding(.leading, 24)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .center)
        .background(Color.ampWhite)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ampDivider)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
    }
}

private struct SearchAlbumRow: View {
    let title: String
    let artist: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.listTitle)
                    .foregroundStyle(Color.ampBlack)
                    .lineLimit(1)
                Text(artist)
                    .font(.subtitle)
                    .foregroundStyle(Color.ampMutedText)
                    .lineLimit(1)
            }
            .padding(.leading, 24)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .center)
        .background(Color.ampWhite)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ampDivider)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel("\(title) by \(artist)")
        .accessibilityAddTraits(.isButton)
    }
}
