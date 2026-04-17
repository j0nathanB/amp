import SwiftUI
import MediaPlayer
import AVKit

// Spec §7.6 + layout revision: tab root for the Active tab. Art takes
// nearly the full content-frame width; title + artist info strip; big
// Prev / Play-Pause / Next transport row sits lower in the frame;
// BT / Loop / Lyrics / Like are tucked behind a hideable "more" tray
// at the bottom-right.

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var nav = NavigationService.shared
    @ObservedObject private var liked = LikedTracksService.shared
    @ObservedObject private var settings = SettingsService.shared

    @State private var showMore = false

    var body: some View {
        VStack(spacing: 16) {
            AlbumArtView(song: audioPlayer.enrichedCurrentTrack ?? audioPlayer.currentTrack)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            infoStrip

            Scrubber(
                currentTime: audioPlayer.playbackTime,
                duration: audioPlayer.songDuration,
                onSeek: { audioPlayer.seek(to: $0) }
            )
            .padding(.horizontal, 24)

            Spacer(minLength: 12)

            transportRow

            moreTray
                .padding(.top, 4)
                .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Info strip (§7.6, artist bumped to 75% of title)

    private var infoStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarqueeText(
                text: audioPlayer.currentTrack?.title ?? "—",
                font: .nowPlayingTitle,
                color: Color.ampBlack
            )
            .frame(height: 36)

            MarqueeText(
                text: audioPlayer.currentTrack?.artist ?? "—",
                font: .custom("AtkinsonHyperlegibleNext-Bold", size: 24),
                color: Color.ampBlack
            )
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture {
                guard let id = audioPlayer.currentTrack?.persistentID else { return }
                nav.navigateToArtist(forTrack: id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    // MARK: - Transport row — Prev / Play-Pause / Next only, centered

    private var transportRow: some View {
        HStack(spacing: 20) {
            TransportButton(kind: .previous) {
                audioPlayer.previousTrack()
            }
            TransportButton(kind: .playPause, isPlaying: audioPlayer.isPlaying) {
                audioPlayer.playPause()
            }
            TransportButton(kind: .next) {
                audioPlayer.nextTrack()
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - More tray (BT / Loop / Lyrics / Like behind a chevron toggle)

    private var moreTray: some View {
        HStack(spacing: 12) {
            if showMore {
                bluetoothButton
                    .transition(.opacity.combined(with: .move(edge: .trailing)))

                TransportButton(kind: .loop, isActive: audioPlayer.isLoopingSong) {
                    audioPlayer.toggleSongLoop()
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))

                if settings.showLyrics {
                    LyricsButton {
                        nav.push(.lyrics)
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }

                if let track = audioPlayer.currentTrack {
                    LikeButton(
                        isLiked: liked.isLiked(trackID: track.persistentID),
                        trackTitle: track.title
                    ) {
                        liked.toggleLike(trackID: track.persistentID)
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }

            moreToggle
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 24)
    }

    private var moreToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                showMore.toggle()
            }
        } label: {
            Image(systemName: showMore ? "chevron.down" : "chevron.up")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.ampBlack)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(BrutalistButtonStyle(offset: .small, fillColor: .ampWhite))
        .accessibilityLabel(showMore ? "Hide more actions" : "Show more actions")
    }

    // BT button with AirPlay route picker overlaid for hit testing.
    private var bluetoothButton: some View {
        let isActive = !audioPlayer.currentOutputName.isEmpty
            && audioPlayer.currentOutputName != "iPhone"
        return ZStack {
            TransportButton(kind: .bluetooth, isActive: isActive) {}
                .allowsHitTesting(false)
            AirPlayButton()
                .frame(width: 44, height: 44)
                .accessibilityLabel("Audio output")
        }
    }
}
