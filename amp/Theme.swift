import SwiftUI

struct Theme {
    // Colors from Asset Catalog (static, non-dark-mode-aware)
    static let accentLightGreen = Color("AccentLightGreen")
    static let accentPink = Color("AccentPink")
    static let accentSkyBlue = Color("AccentSkyBlue")
    static let accentYellow = Color("AccentYellow")
    static let accentRed = Color("AccentRed")
    static let accentGreen = Color("AccentGreen")
    static let backgroundColor = Color("BackgroundColor")
    static let touchDownColor = Color("TouchDownColor")

    // Dynamic colors that respond to dark mode
    static var background: Color {
        isDarkMode ? Color.black : Color.white
    }

    static var primaryText: Color {
        isDarkMode ? Color.white : Color.black
    }

    static var secondaryText: Color {
        isDarkMode ? Color.gray : Color.gray
    }

    static var accentIndigo: Color {
        isDarkMode ? Color(red: 0.4, green: 0.4, blue: 0.45) : Color("AccentIndigo")
    }

    static var accentDarkIndigo: Color {
        isDarkMode ? Color(red: 0.45, green: 0.45, blue: 0.5) : Color("AccentDarkIndigo")
    }

    static var accentLightBlue: Color {
        isDarkMode ? Color(red: 0.4, green: 0.6, blue: 0.8) : Color("AccentLightBlue")
    }

    static var accentDarkBlue: Color {
        isDarkMode ? Color(red: 0.3, green: 0.5, blue: 0.7) : Color("AccentDarkBlue")
    }

    static var buttonShadow: Color {
        isDarkMode ? accentYellow : Color("AccentDarkIndigo")
    }

    static var playButtonIcon: Color {
        isDarkMode ? Color.black : Color.white
    }

    static var mainButtonStroke: Color {
        isDarkMode ? Color(white: 0.65) : primaryText
    }

    static var searchShadow: Color {
        isDarkMode ? Color("AccentDarkSpruce") : Color("AccentDarkIndigo")
    }

    // Helper to check dark mode state
    private static var isDarkMode: Bool {
        SettingsService.shared.darkMode
    }
    
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
