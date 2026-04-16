import SwiftUI

// Spec §5.13: height 48, white fill, 4px shadow, 2px stroke.
// Magnifying-glass glyph at left (x=14), text field in the middle, × clear at right when text is present.
// Search happens on type — no submit button.

struct SearchInput: View {
    @Binding var text: String
    var placeholder: String = "Search your library"

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.ampBlack)
                .padding(.leading, 14)
                .padding(.trailing, 10)

            TextField(placeholder, text: $text)
                .font(.listTitle)
                .foregroundStyle(Color.ampBlack)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.ampBlack)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(height: 48)
        .background(Color.ampWhite)
        .brutalistStroke()
        .brutalistShadow(.small)
    }
}

#Preview {
    struct SearchInputPreview: View {
        @State private var empty: String = ""
        @State private var filled: String = "radiohead"
        var body: some View {
            ZStack {
                Color.ampCream.ignoresSafeArea()
                VStack(spacing: 24) {
                    SearchInput(text: $empty)
                    SearchInput(text: $filled)
                }
                .padding(24)
            }
        }
    }
    return SearchInputPreview()
}
