import SwiftUI

struct Theme {
    // Colors
    static let accentGreen = Color(red: 0.749, green: 0.839, blue: 0.188) //     74.9, 83.9, 18.8
    static let accentPink = Color(red: 0.918, green: 0.459, blue: 0.529)      //91.8, 45.9, 52.9
    static let accentBlue = Color(red: 0.06667, green: 0.25882, blue: 1.00000)
    static let accentLightBlue = Color(red: 0.86667, green: 0.96863, blue: 1.00000)
    static let accentDarkBlue = Color(red:0.00000, green:  0.30196, blue:  0.43922)
    static let accentYellow = Color(red: 0.98824, green: 0.86275, blue:  0.24314)
    static let primaryText = Color.black
    static let secondaryText = Color.gray
    static let backgroundColor = Color(red: 0.9, green: 0.9, blue: 0.9)
    static let touchDownColor = Color.black.opacity(0.05) // 5% black for touch states
    static let background = Color.white
    
    // --- Updated Font Hierarchy with Better Weight Differentiation ---
    // The largest font, for main titles in views like NowPlayingView.
    static let titleFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 32)
    
    static let nowPlayingFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 24)
    static let queuePlayingFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 22)
    static let queueSongFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 22)
    
    // Using size variation instead of italics for albums
    static let searchAlbumFont = Font.custom("AtkinsonHyperlegibleMono-Regular", size: 18)
    // The standard font for all list items.
    static let bodyFont = Font.custom("AtkinsonHyperlegiblenext-Regular", size: 18)
    
    // Secondary information with tighter tracking
    static let secondaryInfoFont = Font.custom("AtkinsonHyperlegibleMono-Regular", size: 18)
    
    // A distinct font for section headers in lists.
    static let sectionHeaderFont = Font.custom("AtkinsonHyperlegibleMono-BoldItalic", size: 22)
    
    static let bodyItalicFont = Font.custom("AtkinsonHyperlegibleMono-RegularItalic", size: 18)
    
    static let tabFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 18)
    static let tabFontSelected = Font.custom("AtkinsonHyperlegibleMono-Bold", size: 16)
}
