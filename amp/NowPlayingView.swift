import SwiftUI
import MediaPlayer

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        VStack(spacing: 0) {
            PlayerArtworkView()

//            Spacer(minLength: 10)

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
        .background(Color.white)
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
                    AlbumInfoView(song: currentTrack)
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
        Group {
            if let image = artwork {
                Image(uiImage: image).resizable()
            } else {
                Image(systemName: "circle.fill").resizable().padding(70).foregroundStyle(Theme.accentGreen)
            }
        }
        .aspectRatio(contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.primaryText, lineWidth: 2))
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
                .font(Theme.nowPlayingFont)
                .foregroundColor(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)

            // Artist - fixed height container
            Text(track?.artist ?? "Artist")
                .font(Theme.bodyFont)
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

    private let thumbWidth: CGFloat = 36  // Wider rectangle
    private let thumbHeight: CGFloat = 32 // Extends beyond the bar
    private let barHeight: CGFloat = 1   // Original bar height

    var body: some View {
        HStack(spacing: 12) {
            Text("\(formatTime(audioPlayer.playbackTime))")
                .font(Theme.tabFontSelected)
                .foregroundColor(Theme.primaryText)

            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                // The track is now shorter to make room for the thumb on both sides
                let trackWidth = totalWidth - thumbWidth
                let progress = audioPlayer.songDuration > 0 ? audioPlayer.playbackTime / audioPlayer.songDuration : 0
                // The thumb's position along the track
                let thumbOffset = trackWidth * progress

                ZStack(alignment: .leading) {
                    // Background of the progress bar
                    Rectangle()
                        .fill(Theme.accentGreen)
                        .stroke(Theme.primaryText, lineWidth: 2)
                        .frame(height: barHeight)

                    // The elapsed progress portion
                    Rectangle()
                        .fill(Theme.backgroundColor) // Changed to lime green
                        .stroke(Theme.primaryText, lineWidth: 2)
                    // The width is calculated based on playback progress
                    .frame(width: geometry.size.width * progress, height: barHeight)

                    // The draggable square slider thumb
                    Rectangle()
                        .fill(.white)
                        .stroke(Theme.primaryText, lineWidth: 2)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .offset(x: thumbOffset) // Position the thumb

                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let percentage = max(0, min(1, value.location.x / geometry.size.width))
                            let newTime = audioPlayer.songDuration * percentage
                            audioPlayer.seek(to: newTime)
                        }
                )
            }
            .frame(height: thumbHeight)

            Text("\(formatTime(audioPlayer.songDuration))")
                .font(Theme.tabFontSelected)
                .foregroundColor(Theme.primaryText)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct PlayerControlsView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

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
                        .fill(Theme.accentSkyBlue)
                        .frame(width: 132, height: 44)
                        .offset(x: -4, y: 4)

                    // Main container
                    ZStack {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 132, height: 44)

                        AirPlayButton()
                            .frame(width: 132, height: 44)
                            .overlay(
                                Text(audioPlayer.currentOutputName)
                                    .font(Theme.bodyFont.weight(.regular))
                                    .foregroundColor(Theme.secondaryText)
                                    .allowsHitTesting(false)
                            )
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.primaryText, lineWidth: 2)
                    )
                }

                // Loop button
                Button(action: {
                    // TODO: Add loop functionality
                }) {
                    ZStack {
                        // Shadow layer
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.accentDarkIndigo)
                            .frame(width: 44, height: 44)
                            .offset(x: -4, y: 4)

                        // Main button
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 44, height: 44)

                        Image(systemName: "repeat")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.primaryText)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.primaryText, lineWidth: 2)
                    )
                }

                // Lyrics button
                Button(action: {
                    // TODO: Add lyrics functionality
                }) {
                    ZStack {
                        // Shadow layer
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.accentDarkIndigo)
                            .frame(width: 44, height: 44)
                            .offset(x: -4, y: 4)

                        // Main button
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 44, height: 44)

                        Image(systemName: "quote.bubble")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.primaryText)
                    }
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
            ZStack {
                // Layer 1: The hard shadow (offset background)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accentDarkGreen)
                    .frame(width: 82, height: 82)
                    .offset(x: -6, y: 6)

                // Layer 2: The main button background
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 82, height: 82)

                // Layer 3: The icon
                Image(systemName: icon)
                    .font(isLarge ? .system(size: 44) : .largeTitle)
                    .foregroundColor(Theme.primaryText)
            }
        }
        .buttonStyle(PlayerButtonStyle())
    }
}

// Custom button style for player controls
struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .colorInvert()
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
