import SwiftUI

// Spec §8.5: alphabetic scrubber rail on the right edge of long lists.
// When the user drags, scrollTo the matching section and show a large
// letter indicator — 72×72 white brutalist box centered on screen,
// dismissing ~300ms after release.

struct AlphabetScrubber: View {
    let letters: [String]
    let onLetterChanged: (String) -> Void
    let onDragEnded: () -> Void

    @State private var currentLetter: String?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.custom("AtkinsonHyperlegibleMono-Bold", size: 11))
                        .foregroundStyle(Color.ampBlack)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let count = letters.count
                        guard count > 0, geo.size.height > 0 else { return }
                        let rowHeight = geo.size.height / CGFloat(count)
                        let clamped = max(0, min(CGFloat(count - 1), value.location.y / rowHeight))
                        let i = min(count - 1, Int(clamped))
                        let letter = letters[i]
                        if letter != currentLetter {
                            currentLetter = letter
                            onLetterChanged(letter)
                        }
                    }
                    .onEnded { _ in
                        currentLetter = nil
                        onDragEnded()
                    }
            )
        }
        .frame(width: 18)
    }
}

// 72×72 white brutalist box with the current letter. Shown while the
// user drags along the rail; parent is responsible for timing its
// dismissal (spec: ~300ms after release).

struct BigLetterIndicator: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(.viewTitle)
            .foregroundStyle(Color.ampWhite)
            .frame(width: 72, height: 72)
            .background(Color.ampNavy)
            .brutalistStroke()
            .accessibilityHidden(true)
    }
}

// Grouping helpers used by any view that wants to section a list by
// first letter. Non-alphabetic first characters collapse into "#".

enum AlphabetSectioning {
    static func key(for value: String) -> String {
        guard let ch = value.first else { return "#" }
        let upper = String(ch).uppercased()
        return upper.first?.isLetter == true ? upper : "#"
    }

    static func sortedKeys(_ keys: some Sequence<String>) -> [String] {
        // "#" always first, then A-Z alphabetically.
        Array(keys).sorted { a, b in
            if a == "#" && b != "#" { return true }
            if b == "#" && a != "#" { return false }
            return a < b
        }
    }
}
