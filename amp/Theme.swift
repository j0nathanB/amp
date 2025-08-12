import SwiftUI

struct Theme {
    // Colors
    static let accentGreen = Color(red: 0.749, green: 0.839, blue: 0.188) //     74.9, 83.9, 18.8
    static let accentPink = Color(red: 0.918, green: 0.459, blue: 0.529)      //91.8, 45.9, 52.9
    static let primaryText = Color.black
    static let secondaryText = Color.gray
    static let backgroundColor = Color(red: 0.9, green: 0.9, blue: 0.9)
    static let touchDownColor = Color.black.opacity(0.05) // 5% black for touch states
    
    // --- Updated Font Hierarchy with Better Weight Differentiation ---
    // The largest font, for main titles in views like NowPlayingView.
    static let titleFont = Font.custom("AtkinsonHyperlegibleMono-Bold", size: 32)
    
    static let nowPlayingFont = Font.custom("AtkinsonHyperlegibleMono-Bold", size: 24)
    static let queuePlayingFont = Font.custom("AtkinsonHyperlegibleMono-Bold", size: 20)
    static let queueSongFont = Font.custom("AtkinsonHyperlegibleMono-Regular", size: 20)
    
    // Using size variation instead of italics for albums
    static let searchAlbumFont = Font.custom("AtkinsonHyperlegibleMono-Regular", size: 18)
    // The standard font for all list items.
    static let bodyFont = Font.custom("AtkinsonHyperlegibleMono-Regular", size: 18)
    
    // Secondary information with tighter tracking
    static let secondaryInfoFont = Font.custom("AtkinsonHyperlegibleMono-Regular", size: 18)
    
    // A distinct font for section headers in lists.
    static let sectionHeaderFont = Font.custom("AtkinsonHyperlegibleMono-BoldItalic", size: 18)
    
    static let bodyItalicFont = Font.custom("AtkinsonHyperlegibleMono-RegularItalic", size: 18)
    
    static let tabFont = Font.custom("AtkinsonHyperlegibleMono-Regular", size: 14)
    static let tabFontSelected = Font.custom("AtkinsonHyperlegibleMono-Bold", size: 14)
}
