import SwiftUI

// Spec §5.9 + §6: 72×56 tab, 4px shadow when unselected; selected = navy inversion, no shadow.
// Icon in upper ~32px, .tabLabel at baseline ~y=48.
// AmpTab itself lives in DataModels.swift since it's used across services.

struct TabBarTab: View {
    let tab: AmpTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                icon
                    .frame(width: 28, height: 28)
                Text(tab.rawValue)
                    .font(.tabLabel)
                    .foregroundStyle(isSelected ? Color.ampWhite : Color.ampBlack)
            }
            .animation(.easeInOut(duration: 0.25), value: isSelected)
            .frame(width: 72, height: 56)
        }
        .buttonStyle(BrutalistInvertibleButtonStyle(isActive: isSelected, offset: .small))
        .accessibilityLabel(tab.rawValue.capitalized)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        let color = isSelected ? Color.ampWhite : Color.ampBlack
        switch tab {
        case .library: LibraryTabGlyph(color: color)
        case .search: SearchTabGlyph(color: color)
        case .queue: QueueTabGlyph(color: color)
        case .active: ActiveTabGlyph(color: color)
        }
    }
}

private struct LibraryTabGlyph: View {
    let color: Color
    var body: some View {
        VStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 26, height: 2)
            Rectangle().fill(color).frame(width: 26, height: 2)
            Rectangle().fill(color).frame(width: 26, height: 2)
        }
    }
}

private struct SearchTabGlyph: View {
    let color: Color
    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .stroke(color, lineWidth: 2)
                .frame(width: 16, height: 16)
                .offset(x: 2, y: 2)
            Path { p in
                p.move(to: CGPoint(x: 22, y: 22))
                p.addLine(to: CGPoint(x: 28, y: 28))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 28, height: 28)
    }
}

private struct QueueTabGlyph: View {
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            VStack(spacing: 5) {
                Circle().fill(color).frame(width: 3.6, height: 3.6)
                Circle().fill(color).frame(width: 3.6, height: 3.6)
                Circle().fill(color).frame(width: 3.6, height: 3.6)
            }
            VStack(spacing: 5) {
                Rectangle().fill(color).frame(width: 20, height: 2)
                Rectangle().fill(color).frame(width: 20, height: 2)
                Rectangle().fill(color).frame(width: 20, height: 2)
            }
        }
    }
}

private struct ActiveTabGlyph: View {
    let color: Color
    var body: some View {
        Triangle(pointing: .right)
            .fill(color)
            .frame(width: 14, height: 16)
    }
}

#Preview {
    ZStack {
        Color.ampCream.ignoresSafeArea()
        HStack(spacing: 8) {
            TabBarTab(tab: .library, isSelected: true, action: {})
            TabBarTab(tab: .search, isSelected: false, action: {})
            TabBarTab(tab: .queue, isSelected: false, action: {})
            TabBarTab(tab: .active, isSelected: false, action: {})
        }
    }
}
