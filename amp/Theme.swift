import SwiftUI

struct Theme {
    // Colors from Asset Catalog
    static let accentGreen = Color("AccentGreen")
    static let accentPink = Color("AccentPink")
    static let accentBlue = Color("AccentBlue")
    static let accentLightBlue = Color("AccentLightBlue")
    static let accentSkyBlue = Color("AccentSkyBlue")
    static let accentDarkBlue = Color("AccentDarkBlue")
    static let accentDarkIndigo = Color("AccentDarkIndigo")
    static let accentYellow = Color("AccentYellow")
    static let accentDarkGreen = Color("AccentDarkGreen")
    static let accentRed = Color("AccentRed")
    static let primaryText = Color.black
    static let secondaryText = Color.gray
    static let backgroundColor = Color("BackgroundColor")
    static let touchDownColor = Color("TouchDownColor")
    static let background = Color.white
    
    // --- Updated Font Hierarchy with Better Weight Differentiation ---
    // The largest font, for main titles in views like NowPlayingView.
    static let titleFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 32)
    
    static let nowPlayingTrackFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 30)
    static let nowPlayingArtistFont = Font.custom("AtkinsonHyperlegibleNext-Regular", size: 22)
    static let queuePlayingFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 22)
    static let queueSongFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 22)
    
    // Using size variation instead of italics for albums
    static let searchAlbumFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 22)
    // The standard font for all list items.
    static let bodyFont = Font.custom("AtkinsonHyperlegibleNext-Regular", size: 18)
    
    // Secondary information with tighter tracking
    static let secondaryInfoFont = Font.custom("AtkinsonHyperlegibleMono-Regular", size: 18)
    
    // A distinct font for section headers in lists.
    static let sectionHeaderFont = Font.custom("AtkinsonHyperlegibleMono-Bold", size: 22)
    
    static let bodyItalicFont = Font.custom("AtkinsonHyperlegibleNext-RegularItalic", size: 18)
    
    static let tabFont = Font.custom("AtkinsonHyperlegibleNext-Bold", size: 18)
    static let tabFontSelected = Font.custom("AtkinsonHyperlegibleNext-Regular", size: 16)
}
