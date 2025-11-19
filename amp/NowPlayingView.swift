import SwiftUI
import MediaPlayer

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        // Main content
        VStack(spacing: 0) {
            PlayerArtworkView()

            VStack(spacing: 18) {
                PlayerTrackInfoView(track: audioPlayer.currentTrack)
                    .padding(.top, 12)

                PlayerProgressView()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                PlayerControlsView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 22)
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

    var body: some View {
        // Always maintain the same frame size for consistent layout
        Group {
            if let currentTrack = audioPlayer.currentTrack {
                if showInfo {
                    // Use enrichedCurrentTrack for album info (includes metadata from audio file)
                    AlbumInfoView(song: audioPlayer.enrichedCurrentTrack ?? currentTrack)
                        .onTapGesture {
                            showInfo = false
                        }
                } else {
                    ArtworkImage(song: currentTrack)
                        .onTapGesture {
                            showInfo = true
                        }
                }
            } else {
                // Default artwork when no track is playing - same size as when loaded
                Image(systemName: "circle.fill")
                    .resizable()
                    .padding(70)
                    .foregroundStyle(Theme.accentGreen)
            }
        }
        .frame(maxWidth: .infinity) // Let it fill available width
        .aspectRatio(1, contentMode: .fit) // Keep it square
        .animation(.none, value: showInfo) // Prevent resize animation when toggling
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
                        .foregroundStyle(Theme.accentGreen)
                        .frame(width: geometry.size.width, height: geometry.size.width)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.primaryText, lineWidth: 2))
        }
        .aspectRatio(1, contentMode: .fit)  // Force square container
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
            // Title - fixed height container
            Text(track?.title ?? "Track")
                .font(Theme.nowPlayingTrackFont)
                .foregroundColor(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)

            // Artist - fixed height container
            Text(track?.artist ?? "Artist")
                .font(Theme.nowPlayingArtistFont)
                .foregroundColor(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
                    .fill(Theme.accentDarkGreen)
                    .stroke(Theme.primaryText, lineWidth: 2)
                    .frame(height: barHeight)

                // The elapsed progress portion
                Rectangle()
                    .fill(Theme.backgroundColor)
                    .stroke(Theme.primaryText, lineWidth: 2)
                    .frame(width: geometry.size.width * progress, height: barHeight)

                // The draggable circular slider thumb
                Circle()
                    .fill(isPlaying ? Theme.accentGreen : Theme.accentPink)
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
                PlayerControlButton(action: { audioPlayer.previousTrack() }, icon: "backward.fill")
                PlayerControlButton(action: { audioPlayer.playPause() }, icon: audioPlayer.isPlaying ? "pause.fill" : "play.fill", isLarge: true)
                // --- CORRECTED ACTION ---
                PlayerControlButton(action: { audioPlayer.nextTrack() }, icon: "forward.fill")
                Spacer()
            }

            HStack(spacing: 24) {
                // Speaker/AirPlay button in rounded box with shadow
                ZStack {
                    // Shadow layer
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accentDarkIndigo)
                        .frame(width: 126, height: 44)
                        .offset(x: -4, y: 4)

                    // Main container
                    ZStack {
                        Rectangle()
                            .fill(audioPlayer.isPlaying ? Theme.accentLightBlue : Color.white)
                            .frame(width: 126, height: 44)

                        AirPlayButton()
                            .frame(width: 126, height: 44)
                            .overlay(
                                Text(audioPlayer.currentOutputName)
                                    .font(Theme.bodyFont)
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
                        // Shadow layer
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.accentDarkIndigo)
                            .offset(x: -4, y: 4)

                        // Main container
                        Rectangle()
                            .fill(audioPlayer.isLoopingSong ? Theme.accentPink : Color.white)
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
                            // Shadow layer
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.accentDarkIndigo)
                                .offset(x: -4, y: 4)

                            // Main button background
                            Rectangle()
                                .fill(Color.white)
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

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(isLarge ? .system(size: 44) : .largeTitle)
                .foregroundColor(isLarge ? Color.white : Theme.accentGreen)
        }
        .frame(width: 82, height: 82)
        .background(
            ZStack {
                // Layer 1: The hard shadow (offset background)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accentDarkIndigo)
                    .offset(x: -6, y: 6)

                // Layer 2: The main button background
                Rectangle()
                    .fill(isLarge ? icon == "pause.fill" ? Theme.accentPink : Theme.accentGreen : Color.white)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.primaryText, lineWidth: 2)
        )
    }
}

extension View {
    func iconStroke(fillColor: Color, strokeColor: Color, strokeWidth: CGFloat = 1) -> some View {
        self
            .foregroundColor(strokeColor)
            .shadow(color: strokeColor, radius: 0, x: -strokeWidth, y: -strokeWidth)
            .shadow(color: strokeColor, radius: 0, x: strokeWidth, y: -strokeWidth)
            .shadow(color: strokeColor, radius: 0, x: -strokeWidth, y: strokeWidth)
            .shadow(color: strokeColor, radius: 0, x: strokeWidth, y: strokeWidth)
            .foregroundColor(fillColor)
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
            InfoRow(label: "Song", value: song.title)
            InfoRow(label: "Artist", value: song.artist)
            InfoRow(label: "Album", value: song.album)
            InfoRow(label: "Year", value: yearString)
            InfoRow(label: "Genre", value: song.genre ?? "Unknown")
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity) // Match artwork dimensions exactly
        .background(Color.white)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.primaryText, lineWidth: 2))
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text("\(label):")
                .font(Theme.bodyFont.weight(.semibold))
                .foregroundColor(Theme.primaryText)
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(Theme.bodyFont)
                .foregroundColor(Theme.primaryText)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
