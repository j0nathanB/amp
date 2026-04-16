import SwiftUI

// Spec §5.4: two variants.
// Regular: 48 tall, track# right-aligned at x≈36, title at x=56, duration right-aligned.
// Navy-inverted: 64 tall, full-bleed ampNavy, equalizer bars replacing track#, white text.
//
// Uses .onTapGesture + .contentShape instead of Button so the outer frame
// stays authoritative for LazyVStack sizing (see ArtistRow for background).

struct TrackRow: View {
    let position: String
    let title: String
    let duration: String
    let isCurrent: Bool
    let onTap: () -> Void
    let onLongPress: (() -> Void)?

    init(
        position: String,
        title: String,
        duration: String,
        isCurrent: Bool,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil
    ) {
        self.position = position
        self.title = title
        self.duration = duration
        self.isCurrent = isCurrent
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

    private var regular: some View {
        HStack(spacing: 0) {
            Text(position)
                .font(.trackNumber)
                .foregroundStyle(Color.ampMutedTextStrong)
                .frame(width: 40, alignment: .trailing)
            Text(title)
                .font(.listTitleMedium)
                .foregroundStyle(Color.ampBlack)
                .lineLimit(1)
                .padding(.leading, 16)
            Spacer(minLength: 12)
            Text(duration)
                .font(.timestamp)
                .foregroundStyle(Color.ampMutedText)
                .padding(.trailing, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ampDivider)
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
    }

    private var navyInverted: some View {
        HStack(spacing: 0) {
            EqualizerBars(color: .ampWhite)
                .frame(width: 18)
                .padding(.leading, 24)
            Text(title)
                .font(.listTitle)
                .foregroundStyle(Color.ampWhite)
                .lineLimit(1)
                .padding(.leading, 14)
            Spacer(minLength: 12)
            Text(duration)
                .font(.timestamp)
                .foregroundStyle(Color.ampWhite)
                .padding(.trailing, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(Color.ampNavy)
    }

    private var accessibilityText: String {
        if isCurrent {
            return "Now playing: \(title), \(duration)"
        }
        return "Track \(position): \(title), \(duration)"
    }
}

#Preview {
    ZStack {
        Color.ampWhite.ignoresSafeArea()
        VStack(spacing: 0) {
            TrackRow(position: "6", title: "Optimistic", duration: "5:15", isCurrent: false, onTap: {})
            TrackRow(position: "7", title: "In Limbo", duration: "3:31", isCurrent: false, onTap: {})
            TrackRow(position: "8", title: "Idioteque", duration: "5:09", isCurrent: true, onTap: {})
            TrackRow(position: "9", title: "Morning Bell", duration: "4:35", isCurrent: false, onTap: {})
        }
    }
}
