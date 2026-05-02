import SwiftUI

// Loading indicator: a small replica of the app icon (four colored
// bars over a black AMP wordmark band) that pulses in and out.
// Used as the placeholder while async data hydrates (queue, library,
// now playing).
//
// Colors and proportions sampled from
// Assets.xcassets/AppIcon.appiconset/ItunesArtwork@2x.png.
//
// Struct name kept as `EqualizerBars` to avoid touching call sites; the
// implementation has evolved past the literal three-bar EQ.
struct EqualizerBars: View {
    var size: CGFloat = 96

    @State private var pulsed: Bool = false

    private static let barColors: [Color] = [
        Color(red: 191/255, green:  61/255, blue:  55/255), // #BF3D37 red
        Color(red: 242/255, green: 188/255, blue:  64/255), // #F2BC40 yellow
        Color(red:  94/255, green: 205/255, blue: 138/255), // #5ECD8A green
        Color(red:  65/255, green: 145/255, blue: 221/255)  // #4191DD blue
    ]

    // Icon proportions: bars take 70.31% of the height, AMP band 29.69%.
    private var barsHeight: CGFloat { size * 0.7031 }
    private var bandHeight: CGFloat { size * 0.2969 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(EqualizerBars.barColors[i])
                }
            }
            .frame(height: barsHeight)

            ZStack {
                Color.ampBlack
                Text("AMP")
                    .font(.system(size: bandHeight * 0.62, weight: .heavy))
                    .foregroundStyle(Color.ampWhite)
                    .tracking(bandHeight * 0.18)
            }
            .frame(height: bandHeight)
        }
        .frame(width: size, height: size)
        .opacity(pulsed ? 1.0 : 0.35)
        .animation(
            .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: pulsed
        )
        .onAppear { pulsed = true }
        .accessibilityHidden(true)
    }
}

#Preview {
    ZStack {
        Color.ampWhite.ignoresSafeArea()
        EqualizerBars()
    }
}
