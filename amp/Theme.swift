import SwiftUI

// Brutalist typography tokens (redesign spec §3). Color tokens live in the
// Asset Catalog and are auto-exposed by Xcode as Color.ampWhite, .ampNavy,
// etc. — reference them directly without a wrapper type.

extension Font {
    private static let sansRegular = "AtkinsonHyperlegibleNext-Regular"
    private static let sansBold = "AtkinsonHyperlegibleNext-Bold"
    private static let sansItalic = "AtkinsonHyperlegibleNext-RegularItalic"
    private static let monoRegular = "AtkinsonHyperlegibleMono-Regular"
    private static let monoBold = "AtkinsonHyperlegibleMono-Bold"

    // Sizes are the spec §3 values scaled +20% and rounded up, with a 12pt
    // floor. Keeps the relative type hierarchy intact while lifting the
    // smallest labels above iOS's 11pt readability threshold.
    static let viewTitle = Font.custom(monoBold, size: 27)          // was 22
    static let playAllBarTitle = Font.custom(monoBold, size: 22)    // was 18
    static let nowPlayingTitle = Font.custom(sansBold, size: 32)    // was 26
    static let listTitle = Font.custom(sansBold, size: 20)          // was 16
    // Spec calls for weight 500; Atkinson Next ships only Regular + Bold, so Regular is the closest non-emphasized weight.
    static let listTitleMedium = Font.custom(sansRegular, size: 20) // was 16
    // Queue-only: title line sized by scaling the old subtitle→title ratio (20/17) onto the 20pt title.
    static let queueRowTitle = Font.custom(sansBold, size: 24)
    static let bodyBrutalist = Font.custom(sansRegular, size: 22)   // was 18
    static let subtitle = Font.custom(sansRegular, size: 17)        // was 14
    static let subtitleItalic = Font.custom(sansItalic, size: 17)   // was 14
    static let metadata = Font.custom(monoRegular, size: 15)        // was 12
    static let timestamp = Font.custom(monoRegular, size: 16)       // was 13
    static let tabLabel = Font.custom(monoBold, size: 12)           // was 10 (floor)
    static let inversionLabel = Font.custom(monoBold, size: 12)     // was 10 (floor)
    static let trackNumber = Font.custom(monoRegular, size: 16)     // was 13
}
