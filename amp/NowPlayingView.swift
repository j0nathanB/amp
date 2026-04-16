import SwiftUI
import MediaPlayer

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        // Main content
        VStack(spacing: 0) {
            PlayerArtworkView()

            VStack(spacing: 8) {
                PlayerTrackInfoView(track: audioPlayer.currentTrack)
                    .id(audioPlayer.currentTrack?.persistentID)  // Force fresh state on song change (fixes scroll carryover)
                    .padding(.top, 12)

                PlayerProgressView()
                    .padding(.horizontal, 16)
//                    .padding(.top, 6)
                    .padding(.bottom, 4)

                PlayerControlsView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, -8)
        .overlay(
            Rectangle()
                .stroke(Theme.primaryText, lineWidth: 0)
        )
    }
}


// MARK: - Child Views

private struct PlayerArtworkView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var showInfo = false
    @State private var selectedArtist: Artist?
    @State private var selectedAlbum: Album?

    var body: some View {
        // Always maintain the same frame size for consistent layout
        Group {
            if let currentTrack = audioPlayer.currentTrack {
                if showInfo {
                    // Use enrichedCurrentTrack for album info (includes metadata from audio file)
                    AlbumInfoView(
                        song: audioPlayer.enrichedCurrentTrack ?? currentTrack,
                        onWhitespaceTap: {
                            showInfo = false
                        },
                        onArtistTap: { artist in
                            selectedArtist = artist
                        },
                        onAlbumTap: { album in
                            selectedAlbum = album
                        },
                        onYearTap: { year in
                            navigateToSearch(with: year)
                        },
                        onGenreTap: { genre in
                            navigateToSearch(with: genre)
                        }
                    )
                } else {
                    ArtworkImage(song: currentTrack)
                        .id(currentTrack.persistentID)  // Force fresh state on song change (fixes art carryover)
                        .onTapGesture {
                            showInfo = true
                        }
                }
            } else {
                // Default artwork when no track is playing - same size as when loaded
                Image(systemName: "circle.fill")
                    .resizable()
                    .padding(70)
                    .foregroundStyle(Theme.accentLightGreen)
            }
        }
        .frame(maxWidth: .infinity) // Let it fill available width
        .aspectRatio(1, contentMode: .fill) // Keep it square and fixed size
        .clipped() // Prevent overflow
        .animation(.none, value: showInfo) // Prevent resize animation when toggling
        .onChange(of: audioPlayer.currentTrack?.persistentID) { _, _ in
            showInfo = false  // Reset to artwork view on song change
        }
        .sheet(item: $selectedArtist) { artist in
            ArtistDetailView(artist: artist, searchResults: SearchResults(artists: [], albums: [], songs: []))
                .environmentObject(audioPlayer)
        }
        .sheet(item: $selectedAlbum) { album in
            AlbumDetailView(album: album, searchResults: SearchResults(artists: [], albums: [], songs: []))
                .environmentObject(audioPlayer)
        }
    }

    private func navigateToSearch(with searchTerm: String) {
        // Navigate to search tab and set search text
        NavigationService.shared.selectedTab = .search
        SearchViewModel.shared.searchText = searchTerm
        SearchViewModel.shared.performSearch()
    }
}

private struct ArtworkImage: View {
    let song: Song

    @State private var artwork: UIImage?
    @State private var loadedSongID: UInt64 = 0

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = artwork {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.width)  // Force exact square dimensions
                        .clipped()  // Clip any overflow from non-square artwork
                } else {
                    Image(systemName: "circle.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(70)
                        .foregroundStyle(Theme.accentLightGreen)
                        .frame(width: geometry.size.width, height: geometry.size.width)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.primaryText, lineWidth: 2))
        }
        .aspectRatio(1, contentMode: .fill)  // Force square container with fixed size
        .clipped()  // Prevent overflow from GeometryReader
        .onChange(of: song.persistentID) { oldValue, newValue in
            // Only reload artwork if the song actually changed
            if newValue != loadedSongID {
                loadArtwork()
            }
        }
        .onAppear {
            // Load artwork on first appearance
            if loadedSongID != song.persistentID {
                loadArtwork()
            }
        }
    }

    private func loadArtwork() {
        artwork = nil  // Clear stale artwork immediately to prevent previous song's art from showing
        loadedSongID = song.persistentID
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: song.persistentID), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        artwork = query.items?.first?.artwork?.image(at: CGSize(width: 500, height: 500))
    }
}

private struct PlayerTrackInfoView: View {
    let track: Song?

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            // Title - scrolling marquee for long titles
            ScrollingText(
                text: track?.title ?? "Track",
                font: Theme.nowPlayingTrackFont,
                color: Theme.primaryText
            )

            // Artist - scrolling marquee for long artist names
            ScrollingText(
                text: track?.artist ?? "Artist",
                font: Theme.nowPlayingArtistFont,
                color: Theme.primaryText
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ScrollingText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animating = false

    private let padding: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in
            Text(text)
                .font(font)
                .foregroundColor(color)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { textGeometry in
                        Color.clear
                            .onAppear {
                                textWidth = textGeometry.size.width
                                containerWidth = geometry.size.width
                                startScrollingIfNeeded()
                            }
                            .onChange(of: text) { _, _ in
                                textWidth = textGeometry.size.width
                                containerWidth = geometry.size.width
                                offset = 0
                                animating = false
                                startScrollingIfNeeded()
                            }
                    }
                )
                .offset(x: needsScrolling ? offset : (geometry.size.width - textWidth) / 2)
                .frame(width: geometry.size.width, alignment: .leading)
                .clipped()
        }
        .frame(height: 36)
    }

    private var needsScrolling: Bool {
        textWidth > containerWidth
    }

    private func startScrollingIfNeeded() {
        guard needsScrolling && !animating else {
            return
        }

        animating = true

        // Start centered, then scroll
        offset = (containerWidth - textWidth) / 2

        // Delay before starting scroll
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            scrollToEnd()
        }
    }

    private func scrollToEnd() {
        // Guard: Don't scroll if no longer needed (e.g., text changed to shorter title)
        guard needsScrolling && animating else { return }

        let scrollDistance = textWidth - containerWidth + padding

        withAnimation(.linear(duration: Double(scrollDistance) / 30)) {
            offset = -scrollDistance
        }

        // Delay at end, then scroll back
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(scrollDistance) / 30 + 1.5) {
            scrollToStart()
        }
    }

    private func scrollToStart() {
        // Guard: Don't scroll if no longer needed (e.g., text changed to shorter title)
        guard needsScrolling && animating else { return }

        let scrollDistance = textWidth - containerWidth + padding

        withAnimation(.linear(duration: Double(scrollDistance) / 30)) {
            offset = (containerWidth - textWidth) / 2
        }

        // Delay at start, then repeat
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(scrollDistance) / 30 + 1.5) {
            if animating {
                scrollToEnd()
            }
        }
    }
}

private struct PlayerProgressView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    private let thumbSize: CGFloat = 32  // Circle diameter
    private let barHeight: CGFloat = 1   // Original bar height
    private let timeLabelWidth: CGFloat = 50  // Fixed width for time labels

    // Pre-calculate progress outside GeometryReader to minimize work
    private var progress: Double {
        audioPlayer.songDuration > 0 ? audioPlayer.playbackTime / audioPlayer.songDuration : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(formatTime(audioPlayer.playbackTime))")
                .font(Theme.tabFontSelected)
                .foregroundColor(Theme.primaryText)
                .frame(width: timeLabelWidth, alignment: .trailing)
                .monospacedDigit()

            // Extracted progress bar into separate view to reduce GeometryReader scope
            ProgressBarTrack(
                progress: progress,
                isPlaying: audioPlayer.isPlaying,
                thumbSize: thumbSize,
                barHeight: barHeight,
                onSeek: { percentage in
                    let newTime = audioPlayer.songDuration * percentage
                    audioPlayer.seek(to: newTime)
                }
            )

            Text("\(formatTime(audioPlayer.songDuration))")
                .font(Theme.tabFontSelected)
                .foregroundColor(Theme.primaryText)
                .frame(width: timeLabelWidth, alignment: .leading)
                .monospacedDigit()
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// Separate view component to isolate GeometryReader and minimize re-layouts
private struct ProgressBarTrack: View {
    let progress: Double
    let isPlaying: Bool
    let thumbSize: CGFloat
    let barHeight: CGFloat
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width - thumbSize
            let thumbOffset = trackWidth * progress

            ZStack(alignment: .leading) {
                // Background of the progress bar
                Rectangle()
                    .fill(Theme.accentGreen)
                    .stroke(Theme.primaryText, lineWidth: 2)
                    .frame(height: barHeight)

                // The elapsed progress portion
                Rectangle()
                    .fill(Theme.backgroundColor)
                    .stroke(Theme.primaryText, lineWidth: 2)
                    .frame(width: geometry.size.width * progress, height: barHeight)

                // The draggable circular slider thumb
                Circle()
                    .fill(isPlaying ? Theme.accentLightGreen : Theme.accentPink)
                    .stroke(Theme.primaryText, lineWidth: 2)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: thumbOffset)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let percentage = max(0, min(1, value.location.x / geometry.size.width))
                        onSeek(percentage)
                    }
            )
        }
        .frame(height: thumbSize)
    }
}

private struct PlayerControlsView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @StateObject private var settings = SettingsService.shared

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 20) {
                Spacer()
                // --- CORRECTED ACTION ---
                PlayerControlButton(action: { audioPlayer.previousTrack() }, icon: "backward.end.fill")
                PlayerControlButton(action: { audioPlayer.playPause() }, icon: audioPlayer.isPlaying ? "pause.fill" : "play.fill", isLarge: true)
                // --- CORRECTED ACTION ---
                PlayerControlButton(action: { audioPlayer.nextTrack() }, icon: "forward.end.fill")
                Spacer()
            }

            HStack(spacing: 24) {
                // Speaker/AirPlay button in rounded box with shadow
                ZStack {
                    // Shadow layer - only show in light mode
                    if !settings.darkMode {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.buttonShadow)
                            .frame(width: 126, height: 44)
                            .offset(x: -4, y: 4)
                    }

                    // Main container
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(audioPlayer.isPlaying ? Theme.accentLightBlue : Theme.background)
                            .frame(width: 126, height: 44)

                        AirPlayButton()
                            .frame(width: 126, height: 44)
                            .overlay(
                                Text(audioPlayer.currentOutputName)
                                    .font(Theme.bodyFont)
                                    .foregroundColor(settings.darkMode && audioPlayer.isPlaying ? Theme.background : Theme.primaryText)
                                    .allowsHitTesting(false)
                            )
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.primaryText, lineWidth: 2)
                    )
                }

                // Loop button (song loop)
                Button(action: {
                    audioPlayer.toggleSongLoop()
                }) {
                    Text("Loop")
                        .font(Theme.bodyFont)
                        .foregroundColor(audioPlayer.isLoopingSong ? Color.white : Theme.primaryText)
                }
                .frame(width: 63, height: 44)
                .background(
                    ZStack {
                        // Shadow layer - only show in light mode
                        if !settings.darkMode {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.buttonShadow)
                                .offset(x: -4, y: 4)
                        }

                        // Main container
                        RoundedRectangle(cornerRadius: 6)
                            .fill(audioPlayer.isLoopingSong ? Theme.accentPink : Theme.background)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.primaryText, lineWidth: 2)
                )

                // Lyrics button - conditionally shown based on settings
                if settings.showLyrics {
                    Button(action: {
                        // TODO: Add lyrics functionality
                    }) {
                        Text("Lyrics")
                            .font(Theme.bodyFont)
                            .foregroundColor(Theme.primaryText)
                    }
                    .frame(width: 68, height: 44)
                    .background(
                        ZStack {
                            // Shadow layer - only show in light mode
                            if !settings.darkMode {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.buttonShadow)
                                    .offset(x: -4, y: 4)
                            }

                            // Main button background
                            Rectangle()
                                .fill(Theme.background)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.primaryText, lineWidth: 2)
                    )
                }
            }
        }
    }
}

// A new reusable view for the bordered buttons
private struct PlayerControlButton: View {
    let action: () -> Void
    let icon: String
    var isLarge: Bool = false
    @StateObject private var settings = SettingsService.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(isLarge ? .system(size: 50) : .largeTitle)
                .foregroundColor(isLarge ? Theme.playButtonIcon : Theme.accentLightGreen)
        }
        .frame(width: 82, height: 82)
        .background(
            ZStack {
                // Layer 1: The hard shadow (offset background) - only show in light mode
                if !settings.darkMode {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.buttonShadow)
                        .frame(width: 82, height: 82)
                        .offset(x: -6, y: 6)
                }

                // Layer 2: The main button background
                RoundedRectangle(cornerRadius: 6)
                    .fill(isLarge ? icon == "pause.fill" ? Theme.accentPink : Theme.accentLightGreen : Theme.background)
                    .frame(width: 82, height: 82)
            }
        )
        .overlay(
            Group {
                if settings.darkMode {
                    // Simple outlines in dark mode
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isLarge ? Color.black : Color.white, lineWidth: 2)
                } else {
                    // Uniform stroke for light mode
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.primaryText, lineWidth: 2)
                }
            }
        )
    }
}

extension View {
    func iconStroke(fillColor: Color, strokeColor: Color, strokeWidth: CGFloat = 1) -> some View {
        if SettingsService.shared.darkMode {
            // No shadow in dark mode
            return AnyView(self.foregroundColor(fillColor))
        } else {
            // Full shadow effect in light mode
            return AnyView(
                self
                    .foregroundColor(strokeColor)
                    .shadow(color: strokeColor, radius: 0, x: -strokeWidth, y: -strokeWidth)
                    .shadow(color: strokeColor, radius: 0, x: strokeWidth, y: -strokeWidth)
                    .shadow(color: strokeColor, radius: 0, x: -strokeWidth, y: strokeWidth)
                    .shadow(color: strokeColor, radius: 0, x: strokeWidth, y: strokeWidth)
                    .foregroundColor(fillColor)
            )
        }
    }
}

// Custom button style for player controls
struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 1 : 0)
            .overlay(
                configuration.label
                    .opacity(configuration.isPressed ? 0 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.primaryText, lineWidth: 2)
            )
    }
}

private struct AlbumInfoView: View {
    let song: Song
    let onWhitespaceTap: () -> Void
    let onArtistTap: (Artist) -> Void
    let onAlbumTap: (Album) -> Void
    let onYearTap: (String) -> Void
    let onGenreTap: (String) -> Void

    private var yearString: String {
        if let releaseDate = song.releaseDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy"

            return formatter.string(from: releaseDate)
        }
        return "Unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InfoRow(label: "Song", value: song.title, isClickable: false, onValueTap: {})
            InfoRow(label: "Artist", value: song.artist, isClickable: true) {
                if let artist = getArtistFromSong() {
                    onArtistTap(artist)
                }
            }
            InfoRow(label: "Album", value: song.album, isClickable: true) {
                if let album = getAlbumFromSong() {
                    onAlbumTap(album)
                }
            }
            InfoRow(label: "Year", value: yearString, isClickable: true) {
                onYearTap(yearString)
            }
            InfoRow(label: "Genre", value: song.genre ?? "Unknown", isClickable: true) {
                onGenreTap(song.genre ?? "Unknown")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity) // Match artwork dimensions exactly
        .background(Theme.background)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.primaryText, lineWidth: 2))
        .contentShape(Rectangle()) // Make entire view tappable
        .onTapGesture {
            // This handles taps on whitespace
            onWhitespaceTap()
        }
    }

    private func getArtistFromSong() -> Artist? {
        // Query the media library to get the artist persistent ID
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: song.persistentID), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)

        guard let item = query.items?.first else { return nil }

        return Artist(id: item.artistPersistentID, name: song.artist)
    }

    private func getAlbumFromSong() -> Album? {
        // Query the media library to get the album persistent ID
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: song.persistentID), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)

        guard let item = query.items?.first else { return nil }

        return Album(id: item.albumPersistentID, title: song.album, artist: song.artist)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    let isClickable: Bool
    let onValueTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text("\(label):")
                .font(Theme.bodyFont.weight(.semibold))
                .foregroundColor(Theme.primaryText)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(Theme.bodyFont)
                .foregroundColor(isClickable ? Color.accentDarkSpruce : Theme.primaryText)
                .underline(isClickable)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isClickable {
                        onValueTap()
                    }
                }
        }
    }
}
