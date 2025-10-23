import SwiftUI

struct ListItemView: View {
    let title: String
    let subtitle: String?
    var isPlaying: Bool = false
    let detail: String?
    var italicizeTitle: Bool = false
    var italicizeDetail: Bool = false
    var playPauseAction: (() -> Void)? = nil
    var isPressed: Bool = false
    var showTopBorder: Bool = true
    var showBottomBorder: Bool = true
    var textAlignment: HorizontalAlignment = .leading

    @EnvironmentObject var audioPlayer: AudioPlayerService
    
    var body: some View {
        Group {
            if textAlignment == .center {
                // Centered layout for playlists
                Text(title)
                    .font(italicizeTitle ? Theme.searchAlbumFont : (isPlaying ? Theme.queuePlayingFont : Theme.queueSongFont))
                    .foregroundColor(isPressed ? .white : (isPlaying ? Theme.accentPink : Theme.primaryText))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                // Left-aligned layout (default)
                HStack {
                    VStack(alignment: .leading) {
                        Text(title)
                            .font(italicizeTitle ? Theme.searchAlbumFont : (isPlaying ? Theme.queuePlayingFont : Theme.queueSongFont))
                            .foregroundColor(isPressed ? .white : (isPlaying ? Theme.accentPink : Theme.primaryText))
                            .lineLimit(1)
                        
                        // Only show the subtitle if it exists
                        if let subtitle = subtitle {
                            Text(subtitle)
                                .font(Theme.bodyFont)
                                .foregroundColor(isPressed ? .white : Theme.primaryText)
                                .tracking(-0.5) // Apply tighter letter spacing here
                                .lineLimit(1)
                        }
                        
                        if let detail = detail {
                            Text(detail)
                                .font(Theme.bodyItalicFont)
                                .foregroundColor(isPressed ? .white : Theme.primaryText)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    if isPlaying {
                        playbackControlButton
                    }
                }
            }
        }
        .padding()
        .background(isPressed ? Theme.accentPink : .white)
        .overlay(
            // Custom border: vertical lines primary, horizontal lines secondary
            ZStack {
                // Left and right borders - primary color
                HStack {
                    Rectangle()
                        .fill(Theme.primaryText)
                        .frame(width: 0)
                    Spacer()
                    Rectangle()
                        .fill(Theme.primaryText)
                        .frame(width: 0)
                }
                
                // Top and bottom borders - secondary color (conditional)
                VStack {
                    if showTopBorder {
                        Rectangle()
                            .fill(Theme.secondaryText)
                            .frame(height: 0)
                    }
                    Spacer()
                    if showBottomBorder {
                        Rectangle()
                            .fill(Theme.secondaryText)
                            .frame(height: 0)
                    }
                }
            }
        )
    }
    
    @ViewBuilder
        private var playbackControlButton: some View {
            Button(action: {
                // If an action was provided, perform it.
                playPauseAction?()
            }) {
                ZStack {
                    // The background color changes based on the player's state
                    Rectangle()
                        .fill(audioPlayer.isPlaying ? Theme.accentPink : Theme.accentGreen)
                        .frame(width: 60, height: 60)
                    
                    // The icon changes based on the player's state
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
}
