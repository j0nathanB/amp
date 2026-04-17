import SwiftUI

// Spec §5.3: height 44, yellow fill, 2px black stroke, 6px navy shadow.
// .viewTitle left-aligned with 16px inset. Not tappable.
// Supports an optional trailing mono-regular count string (used by Queue header: "Queue · 12 tracks").

struct ViewTitleBlock: View {
    let title: String
    let trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.viewTitle)
                .foregroundStyle(Color.ampBlack)
                .padding(.leading, 16)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.metadata)
                    .foregroundStyle(Color.ampBlack)
                    .padding(.trailing, 16)
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Color.ampYellow)
        .brutalistStroke()
        .brutalistShadow(.large)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        VStack(spacing: 32) {
            ViewTitleBlock("LIBRARY")
            ViewTitleBlock("Tracks")
            ViewTitleBlock("Queue", trailing: "12 tracks")
        }
        .padding(24)
    }
}
