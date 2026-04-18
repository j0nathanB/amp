import SwiftUI
import MediaPlayer
import AVKit

// Spec §7.6 + layout revision: tab root for the Active tab. Art takes
// nearly the full content-frame width with matched top / horizontal
// padding so the square art reads as visually inset evenly from all
// three edges. Info strip sits below with title + artist. Prev /
// Play-Pause / Next transport row is centered and lower in the frame.
// BT / Loop / Lyrics / Like always visible at the bottom-right.

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @ObservedObject private var nav = NavigationService.shared
    @ObservedObject private var liked = LikedTracksService.shared
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        Group {
            // During the initial queue restore (~500ms on cold launch),
            // currentTrack is nil and the placeholders flash "—" for
            // title/artist before real data lands. Show the EqualizerBars
            // loader until the restore has completed; once it has, either
            // show the track or a genuine "nothing playing" empty state.
            if audioPlayer.currentTrack == nil && !audioPlayer.queueInitialLoadCompleted {
                EqualizerBars()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                nowPlayingContent
            }
        }
        .background(Color.ampWhite)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var nowPlayingContent: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                VStack(spacing: 12) {
                    // Explicit square, inset 16pt from the frame on all three
                    // sides (top / left / right). Sized off geo.size.width
                    // rather than negotiating through .aspectRatio(.fit) so
                    // it doesn't shrink to match vertical space claimed by
                    // the info strip / scrubber / transport / tray.
                    AlbumArtView(song: audioPlayer.enrichedCurrentTrack ?? audioPlayer.currentTrack)
                        .frame(width: geo.size.width - 32, height: geo.size.width - 32)
                        .padding(.top, 16)

                    infoStrip

                    Scrubber(
                        currentTime: audioPlayer.playbackTime,
                        duration: audioPlayer.songDuration,
                        onSeek: { audioPlayer.seek(to: $0) }
                    )
                    .padding(.horizontal, 24)

                    transportRow
                        .offset(y: -4)

                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                // Pinned to the frame's bottom edge. Button bottoms sit 20pt
                // above the bottom line so the 4px drop shadow lands exactly
                // 16pt from it — matching the album art's 16pt top inset.
                utilityTray
                    .frame(width: geo.size.width)
                    .padding(.bottom, 20)
                    .frame(height: geo.size.height, alignment: .bottom)
            }
        }
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
                font: .custom("AtkinsonHyperlegibleNext-Bold", size: 26),
                color: Color.ampBlack
            )
            .frame(height: 30)
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

    // MARK: - Utility tray (BT / Loop / Lyrics / Like, always visible)

    private var utilityTray: some View {
        HStack(spacing: 20) {
            bluetoothButton

            TransportButton(kind: .loop, isActive: audioPlayer.isLoopingSong) {
                audioPlayer.toggleSongLoop()
            }

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
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
    }

    // Route indicator button:
    // - BT audio active → white bluetooth glyph on a #0693E3 blue fill
    // - BT not in use  → speaker.wave.3.fill in black on white (audio
    //   routed to the iPhone speaker, which is what you fall back to
    //   when BT is disabled or no BT device is connected)
    // 4px shadow in both states — no navy inversion.
    // AirPlayButton overlay handles the tap and presents the system
    // output picker; BrutalistButtonStyle still gets the press event so
    // the shadow-retract animation plays.
    private var bluetoothButton: some View {
        let btBlue = Color(red: 0x06 / 255, green: 0x93 / 255, blue: 0xE3 / 255)
        let isActive = audioPlayer.isBluetoothRouteActive
        return ZStack {
            Button(action: {}) {
                Group {
                    if isActive {
                        BluetoothShape()
                            .stroke(
                                Color.ampWhite,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: 14, height: 22)
                    } else {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.ampBlack)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(BrutalistButtonStyle(offset: .small, fillColor: isActive ? btBlue : .ampWhite))

            AirPlayButton()
                .frame(width: 44, height: 44)
                .accessibilityLabel("Audio output")
        }
    }
}
