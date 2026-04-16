import SwiftUI

// Spec §5.12: full-width (24px side padding), 4px ampDivider track,
// ampGreen progress fill, 16×16 ampGreen playhead with 2px stroke.
// Below: current time left, remaining time right with leading "-".

struct Scrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var dragProgress: Double? = nil

    private var displayProgress: Double {
        if let dragProgress { return dragProgress }
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private var displayTime: TimeInterval {
        if let dragProgress { return dragProgress * duration }
        return currentTime
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let progressW = w * CGFloat(displayProgress)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.ampDivider)
                        .frame(height: 4)
                    Rectangle()
                        .fill(Color.ampGreen)
                        .frame(width: max(0, progressW), height: 4)
                    Circle()
                        .fill(Color.ampGreen)
                        .overlay(Circle().stroke(Color.ampBlack, lineWidth: 2))
                        .frame(width: 16, height: 16)
                        .offset(x: progressW - 8)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let p = min(max(0, value.location.x / w), 1)
                            dragProgress = Double(p)
                        }
                        .onEnded { _ in
                            if let p = dragProgress {
                                onSeek(p * duration)
                            }
                            dragProgress = nil
                        }
                )
            }
            .frame(height: 16)

            HStack {
                Text(format(displayTime))
                    .font(.timestamp)
                    .foregroundStyle(Color.ampMutedText)
                Spacer()
                Text("-" + format(max(0, duration - displayTime)))
                    .font(.timestamp)
                    .foregroundStyle(Color.ampMutedText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scrubber")
        .accessibilityValue("\(format(displayTime)) of \(format(duration))")
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

#Preview {
    ZStack {
        Color.ampWhite.ignoresSafeArea()
        VStack(spacing: 32) {
            Scrubber(currentTime: 0, duration: 309, onSeek: { _ in })
            Scrubber(currentTime: 102, duration: 309, onSeek: { _ in })
            Scrubber(currentTime: 280, duration: 309, onSeek: { _ in })
        }
        .padding(24)
    }
}
