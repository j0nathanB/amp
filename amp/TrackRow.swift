import SwiftUI

// Spec §5.4 + Queue amendment: two variants.
// Regular: 48 tall (or 60 with optional artist line; 72 when prominent).
// Navy-inverted: 64 tall (or 72 with optional artist line; 84 when
// prominent), equalizer bars replace the position number. Equalizer
// animates only while playing — static three-line glyph when paused.
//
// `artist` is Queue-specific; Album Detail passes nil (tracks share the
// album's artist already in the hero info strip).
//
// `prominent` is Queue-only: bumps title/artist to a larger size hierarchy
// (24pt bold title, 20pt artist) and grows the row to match. Playlists
// still use the default sizing.
//
// Uses .onTapGesture + .contentShape instead of Button so the outer frame
// stays authoritative for LazyVStack sizing (see ArtistRow for background).

struct TrackRow: View {
    let position: String
    let title: String
    let artist: String?
    let duration: String
    let isCurrent: Bool
    let isPlaying: Bool
    let prominent: Bool
    let audioLevelProvider: (() -> Float)?
    let onTap: () -> Void
    let onLongPress: (() -> Void)?

    init(
        position: String,
        title: String,
        artist: String? = nil,
        duration: String,
        isCurrent: Bool,
        isPlaying: Bool = false,
        prominent: Bool = false,
        audioLevelProvider: (() -> Float)? = nil,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil
    ) {
        self.position = position
        self.title = title
        self.artist = artist
        self.duration = duration
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.prominent = prominent
        self.audioLevelProvider = audioLevelProvider
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    var body: some View {
        Group {
            if isCurrent {
                navyInverted
            } else {
                regular
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                onLongPress?()
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits([.isButton, isCurrent ? .isSelected : []])
    }

    private var hasArtist: Bool { !(artist?.isEmpty ?? true) }

    private var regularHeight: CGFloat {
        if prominent && hasArtist { return 72 }
        return hasArtist ? 60 : 48
    }
    private var navyHeight: CGFloat {
        if prominent && hasArtist { return 84 }
        return hasArtist ? 72 : 64
    }

    // MARK: - Regular variant

    private var regular: some View {
        HStack(spacing: 0) {
            if !prominent {
                Text(position)
                    .font(.trackNumber)
                    .foregroundStyle(Color.ampMutedTextStrong)
                    .frame(width: 40, alignment: .trailing)
            }
            titleStack(titleColor: Color.ampBlack, artistColor: Color.ampMutedText, boldTitle: false)
                .padding(.leading, prominent ? 24 : 16)
            Spacer(minLength: 12)
            Text(duration)
                .font(.timestamp)
                .foregroundStyle(Color.ampMutedText)
                .padding(.trailing, 24)
        }
        .frame(maxWidth: .infinity, minHeight: regularHeight, maxHeight: regularHeight)
        .background(Color.ampWhite)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ampDivider)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Navy-inverted variant (current track)

    private var navyInverted: some View {
        HStack(spacing: 0) {
            EqualizerBars(
                color: .ampWhite,
                isAnimating: isPlaying,
                levelProvider: audioLevelProvider
            )
            .frame(width: 18)
            .padding(.leading, 24)
            titleStack(titleColor: Color.ampWhite, artistColor: Color.ampInversionLabel, boldTitle: true)
                .padding(.leading, 14)
            Spacer(minLength: 12)
            Text(duration)
                .font(.timestamp)
                .foregroundStyle(Color.ampWhite)
                .padding(.trailing, 24)
        }
        .frame(maxWidth: .infinity, minHeight: navyHeight, maxHeight: navyHeight)
        .background(Color.ampNavy)
    }

    // MARK: - Shared title+artist stack

    @ViewBuilder
    private func titleStack(titleColor: Color, artistColor: Color, boldTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(titleFont(boldTitle: boldTitle))
                .foregroundStyle(titleColor)
                .lineLimit(1)
            if let artist, !artist.isEmpty {
                Text(artist)
                    .font(prominent ? .listTitleMedium : .subtitle)
                    .foregroundStyle(artistColor)
                    .lineLimit(1)
            }
        }
    }

    private func titleFont(boldTitle: Bool) -> Font {
        if prominent { return .queueRowTitle }
        return boldTitle ? .listTitle : .listTitleMedium
    }

    private var accessibilityText: String {
        let subject = [title, artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " by ")
        if isCurrent {
            return "Now playing: \(subject), \(duration)"
        }
        return "Track \(position): \(subject), \(duration)"
    }
}

#Preview {
    ZStack {
        Color.ampWhite.ignoresSafeArea()
        VStack(spacing: 0) {
            TrackRow(position: "1", title: "Everything In Its Right Place", artist: "Radiohead", duration: "4:11", isCurrent: false, onTap: {})
            TrackRow(position: "2", title: "Kid A", artist: "Radiohead", duration: "4:44", isCurrent: false, onTap: {})
            TrackRow(position: "3", title: "The National Anthem", artist: "Radiohead", duration: "5:51", isCurrent: true, isPlaying: true, onTap: {})
            TrackRow(position: "4", title: "How to Disappear Completely", artist: "Radiohead", duration: "5:56", isCurrent: false, onTap: {})
        }
    }
}
