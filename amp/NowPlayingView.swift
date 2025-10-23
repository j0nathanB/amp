import SwiftUI
import MediaPlayer

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        VStack(spacing: 0) {
            PlayerArtworkView()
                .padding(.horizontal, 8) // Reduced horizontal padding for larger artwork
                .padding(.top, 8) // Minimal top padding

            Spacer()

            VStack(spacing: 16) {
                PlayerTrackInfoView(track: audioPlayer.currentTrack)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                PlayerProgressView()
                    .padding(.horizontal, 16)
                    // No horizontal padding - border to border

                PlayerControlsView()
                    .padding(.horizontal, 12) // Standard padding for controls
            }
//            .padding(.bottom, 16) // Bottom spacing from border
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .overlay(
            Rectangle()
                .stroke(Theme.primaryText, lineWidth: 0) // Consistent white border
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
        VStack(alignment: .leading, spacing: 4) {
            // Title - fixed height container  
            Text(track?.title ?? "Track")
                .font(Theme.nowPlayingFont)
                .foregroundColor(Theme.accentPink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: 28, alignment: .leading) // Fixed height for title font
            
            // Artist - fixed height container
            Text(track?.artist ?? "Artist")
                .font(Theme.bodyFont)
                .foregroundColor(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 20, alignment: .leading) // Fixed height to prevent layout shifts
            
            // Album - in a visual container box with fixed height
//            Text(track?.album ?? "Album")
//                .font(Theme.bodyItalicFont)
//                .foregroundColor(Theme.primaryText)
//                .lineLimit(1)
//                .minimumScaleFactor(0.7)
//                .frame(height: 24, alignment: .leading) // Fixed height container
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlayerProgressView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    private let thumbWidth: CGFloat = 36  // Wider rectangle
    private let thumbHeight: CGFloat = 32 // Extends beyond the bar
    private let barHeight: CGFloat = 24   // Original bar height
    
    var body: some View {
        VStack {
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
            // Make the progress bar and thumb thicker
            .frame(height: thumbHeight)

            HStack {
                Spacer()
                Text("\(formatTime(audioPlayer.playbackTime)) | \(formatTime(audioPlayer.songDuration))")
            }
            .font(Theme.tabFont)
            .foregroundColor(.secondary)
//            .padding(.horizontal, 16) // Only pad the time text, not the progress bar
        }
        // Remove padding to make progress bar span full width
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // --- CORRECTED ACTION ---
                PlayerControlButton(action: { audioPlayer.previousTrack() }, icon: "backward.fill")
                Spacer()
                PlayerControlButton(action: { audioPlayer.playPause() }, icon: audioPlayer.isPlaying ? "pause.fill" : "play.fill", isLarge: true)
                Spacer()
                // --- CORRECTED ACTION ---
                PlayerControlButton(action: { audioPlayer.nextTrack() }, icon: "forward.fill")
            }
//            .padding(.horizontal)
            
            AirPlayButton()
                .overlay(
                    Text(audioPlayer.currentOutputName)
                        .font(Theme.bodyFont.weight(.regular))
                        .foregroundColor(Theme.secondaryText)
                        .allowsHitTesting(false)
                )
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
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 100, height: 100)
                
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
