import SwiftUI
import MediaPlayer
import AVKit

// Spec §7.6: tab root for the Active tab. No back button, no shuffle, no
// track-info button. Hero art takes device width minus 48px padding;
// tapping flips to the metadata face (§8.1). Info strip left-aligned
// below art. Scrubber + times. Transport row: BT · Prev · Play/Pause ·
// Next (Loop moved to Queue per spec amendment). Action row: Lyrics + Like.

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var nav = NavigationService.shared
    @ObservedObject private var liked = LikedTracksService.shared
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        VStack(spacing: 20) {
            AlbumArtView(song: audioPlayer.enrichedCurrentTrack ?? audioPlayer.currentTrack)
                .padding(.horizontal, 24)

            infoStrip

            Scrubber(
                currentTime: audioPlayer.playbackTime,
                duration: audioPlayer.songDuration,
                onSeek: { audioPlayer.seek(to: $0) }
            )
            .padding(.horizontal, 24)

            transportRow
                .padding(.top, 8)

            if settings.showLyrics || audioPlayer.currentTrack != nil {
                actionRow
                    .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Info strip (§7.6)

    private var infoStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarqueeText(
                text: audioPlayer.currentTrack?.title ?? "—",
                font: .nowPlayingTitle,
                color: Color.ampBlack
            )
            .frame(height: 32)

            MarqueeText(
                text: audioPlayer.currentTrack?.artist ?? "—",
                font: .listTitle,
                color: Color.ampBlack
            )
            .frame(height: 22)
            .contentShape(Rectangle())
            .onTapGesture {
                guard let id = audioPlayer.currentTrack?.persistentID else { return }
                nav.navigateToArtist(forTrack: id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    // MARK: - Transport row (§7.6)
    //
    // Loop here is SONG loop — repeats the current track only. Queue loop
    // (which repeats the whole queue) lives on the Queue view (Phase G).
    // Two distinct toggles, two different homes.

    private var transportRow: some View {
        HStack(spacing: 0) {
            bluetoothButton
            Spacer()
            TransportButton(kind: .previous) {
                audioPlayer.previousTrack()
            }
            Spacer().frame(width: 12)
            TransportButton(kind: .playPause, isPlaying: audioPlayer.isPlaying) {
                audioPlayer.playPause()
            }
            Spacer().frame(width: 12)
            TransportButton(kind: .next) {
                audioPlayer.nextTrack()
            }
            Spacer()
            TransportButton(kind: .loop, isActive: audioPlayer.isLoopingSong) {
                audioPlayer.toggleSongLoop()
            }
        }
        .padding(.horizontal, 24)
    }

    // BT button: brutalist glyph visually; taps forward to AVRoutePickerView
    // which presents the system output picker. Active state when the current
    // route isn't the built-in speaker.
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

    // MARK: - Action row (§7.6 + §5.15)

    private var actionRow: some View {
        HStack(spacing: 16) {
            Spacer()
            if settings.showLyrics {
                LyricsButton {
                    nav.push(.lyrics)
                }
            }
            if let track = audioPlayer.currentTrack {
                LikeButton(
                    isLiked: liked.isLiked(trackID: track.persistentID),
                    trackTitle: track.title
                ) {
                    liked.toggleLike(trackID: track.persistentID)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}
