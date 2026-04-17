import SwiftUI

// Spec §5.2: height 44, ampGreen fill, 2px stroke, 6px navy shadow.
// Title .playAllBarTitle left-aligned (16px inset), black right-pointing play
// triangle at right edge. Tap plays from track 1; long-press shuffle-plays.
//
// `fillsWidth` defaults to true so Album / Artist / Playlist Detail get
// their full-width bar next to BackButton. Genre Detail opts out — it
// uses a short "Play all" label and wants the bar to size to content so
// the chrome row doesn't look overstuffed.

struct PlayAllBar: View {
    let title: String
    let fillsWidth: Bool
    let onTap: () -> Void
    let onShuffleLongPress: () -> Void

    init(
        title: String,
        fillsWidth: Bool = true,
        onTap: @escaping () -> Void,
        onShuffleLongPress: @escaping () -> Void
    ) {
        self.title = title
        self.fillsWidth = fillsWidth
        self.onTap = onTap
        self.onShuffleLongPress = onShuffleLongPress
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.playAllBarTitle)
                    .foregroundStyle(Color.ampBlack)
                    .lineLimit(1)
                    .padding(.leading, 16)
                if fillsWidth {
                    Spacer(minLength: 12)
                }
                Triangle(pointing: .right)
                    .fill(Color.ampBlack)
                    .frame(width: 18, height: 24)
                    .padding(.trailing, 16)
            }
            .frame(height: 44)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(BrutalistButtonStyle(offset: .large, fillColor: .ampGreen))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in onShuffleLongPress() }
        )
        .accessibilityLabel("Play all of \(title)")
        .accessibilityHint("Long press to shuffle play")
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        VStack(spacing: 24) {
            PlayAllBar(title: "Kid A", onTap: {}, onShuffleLongPress: {})
            PlayAllBar(title: "Dolly Parton", onTap: {}, onShuffleLongPress: {})
        }
        .padding(24)
    }
}
