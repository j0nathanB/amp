import SwiftUI

// Spec §5.14: no button chrome, just mono bold uppercase muted text.
// Example: "CLEAR RECENT" at the bottom of the search recent list.
// Wrap in a 44-tall hit zone for accessibility.

struct TextLink: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(.custom("AtkinsonHyperlegibleMono-Bold", size: 12))
                .foregroundStyle(Color.ampMutedText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#Preview {
    ZStack {
        Color.ampWhite.ignoresSafeArea()
        TextLink(label: "Clear Recent", action: {})
            .padding(.horizontal, 24)
    }
}
