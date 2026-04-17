import SwiftUI

// Shared shapes used by the brutalist component library.
// Triangle points the given direction; rect is fully consumed.

// Classic two-triangles-on-a-vertical-axis bluetooth glyph.
// Used by TransportButton's .bluetooth kind and by NowPlayingView's
// route-indicator button when BT audio is active.

struct BluetoothShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = CGPoint(x: rect.midX, y: rect.minY)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.75)
        let topLeft = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.75)

        p.move(to: top)
        p.addLine(to: topRight)
        p.addLine(to: bottomLeft)
        p.move(to: topLeft)
        p.addLine(to: bottomRight)
        p.addLine(to: bottom)
        p.addLine(to: top)
        return p
    }
}

struct Triangle: Shape {
    enum Direction { case up, down, left, right }
    var pointing: Direction = .right

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch pointing {
        case .right:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        case .left:
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        case .up:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        case .down:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}
