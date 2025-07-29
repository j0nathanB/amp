import SwiftUI

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    
    @State private var animate = false
    @State private var textSize: CGSize = .zero
    @State private var containerWidth: CGFloat = 0
    
    private var shouldScroll: Bool {
        textSize.width > containerWidth
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Hidden text to measure size
                Text(text)
                    .font(font)
                    .fixedSize()
                    .background(GeometryReader { textGeometry in
                        Color.clear.preference(key: SizePreferenceKey.self,
                                             value: textGeometry.size)
                    })
                    .hidden()
                
                // Visible scrolling text
                HStack(spacing: 50) {
                    Text(text)
                        .font(font)
                        .foregroundColor(color)
                        .fixedSize()
                    
                    if shouldScroll {
                        Text(text)
                            .font(font)
                            .foregroundColor(color)
                            .fixedSize()
                    }
                }
                .offset(x: animate && shouldScroll ? -(textSize.width + 50) : 0)
                .animation(animate && shouldScroll ?
                    Animation.linear(duration: Double(textSize.width + 50) / 30)
                        .repeatForever(autoreverses: false) : nil,
                    value: animate)
            }
            .frame(width: geometry.size.width, alignment: .leading)
            .clipped()
            .onPreferenceChange(SizePreferenceKey.self) { size in
                textSize = size
                containerWidth = geometry.size.width
                if shouldScroll && !animate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        animate = true
                    }
                }
            }
        }
        .frame(height: 30) // Fixed height
    }
}

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// Helper view for use in VStacks where we want consistent height
struct MarqueeTextFixed: View {
    let text: String
    let font: Font
    let color: Color
    
    var body: some View {
        MarqueeText(text: text, font: font, color: color)
    }
}
