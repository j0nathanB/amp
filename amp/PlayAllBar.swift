import SwiftUI

// Spec §5.2: height 44, ampGreen fill, 2px stroke, 6px navy shadow.
// Title .playAllBarTitle left-aligned (16px inset), black right-pointing play
// triangle at right edge. Tap plays from track 1; long-press shuffle-plays.

struct PlayAllBar: View {
    let title: String
    let onTap: () -> Void
    let onShuffleLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.playAllBarTitle)
                    .foregroundStyle(Color.ampBlack)
                    .lineLimit(1)
                    .padding(.leading, 16)
                Spacer(minLength: 12)
                Triangle(pointing: .right)
                    .fill(Color.ampBlack)
                    .frame(width: 18, height: 24)
                    .padding(.trailing, 16)
            }
            .frame(height: 44)
            .frame(maxWidth: .infinity)
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
