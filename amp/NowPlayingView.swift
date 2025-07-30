import SwiftUI
import MediaPlayer

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        VStack {
            PlayerArtworkView()
            Spacer()
            VStack {
                PlayerTrackInfoView(track: audioPlayer.currentTrack)
                    .padding(.horizontal)
                PlayerProgressView()
                PlayerControlsView()
            }
        }
        .padding()
        .background(Color.white)
        .overlay(
            Rectangle()
                .stroke(Theme.primaryText, lineWidth: 1)
                .padding(16)
        )
    }
}


// MARK: - Child Views

private struct PlayerArtworkView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        Group {
            if let currentTrack = audioPlayer.currentTrack {
                ArtworkImage(song: currentTrack)
                    .frame(height: 345)
                    .padding(.vertical)
            } else {
                // Default artwork when no track is playing
                Image(systemName: "circle.fill")
                    .resizable()
                    .frame(height: 345)
                    .padding(70)
                    .foregroundStyle(Theme.accentGreen)
                    .padding(.vertical)
            }
        }
    }
}

private struct ArtworkImage: View {
    let song: Song
    
    private var artwork: UIImage? {
        let predicate = MPMediaPropertyPredicate(value: NSNumber(value: song.persistentID), forProperty: MPMediaItemPropertyPersistentID)
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        return query.items?.first?.artwork?.image(at: CGSize(width: 500, height: 500))
    }
    
    var body: some View {
        Group {
            if let image = artwork {
                Image(uiImage: image).resizable()
            } else {
                Image(systemName: "circle.fill").resizable().padding(70).foregroundStyle(Theme.accentGreen)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: 345, height: 345)
        .overlay(Rectangle().stroke(Theme.primaryText, lineWidth: 1))
    }
}

private struct PlayerTrackInfoView: View {
    let track: Song?
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(track?.artist ?? "Artist").font(Theme.bodyFont).foregroundColor(Theme.primaryText)
            Text(track?.title ?? "Track").font(Theme.nowPlayingFont).foregroundColor(Theme.accentPink)
            Text(track?.album ?? "Album").font(Theme.bodyItalicFont).foregroundColor(Theme.primaryText)
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
                        .stroke(Theme.primaryText, lineWidth: 1)
                        .frame(height: barHeight)
                    
                    // The elapsed progress portion
                    Rectangle()
                        .fill(Theme.backgroundColor) // Changed to lime green
                        .stroke(Theme.primaryText, lineWidth: 1)
                    // The width is calculated based on playback progress
                    .frame(width: geometry.size.width * progress, height: barHeight)
                    
                    // The draggable square slider thumb
                    Rectangle()
                        .fill(.white)
                        .stroke(Theme.primaryText, lineWidth: 1)
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
            .padding(.horizontal)
        }
        .padding()
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
            .padding(.horizontal)
            
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
                Rectangle()
                    .stroke(Theme.primaryText, lineWidth: 1)
            )
    }
}
