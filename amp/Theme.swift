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

    static let viewTitle = Font.custom(monoBold, size: 22)
    static let playAllBarTitle = Font.custom(monoBold, size: 18)
    static let nowPlayingTitle = Font.custom(sansBold, size: 26)
    static let listTitle = Font.custom(sansBold, size: 16)
    // Spec calls for weight 500; Atkinson Next ships only Regular + Bold, so Regular is the closest non-emphasized weight.
    static let listTitleMedium = Font.custom(sansRegular, size: 16)
    static let bodyBrutalist = Font.custom(sansRegular, size: 18)
    static let subtitle = Font.custom(sansRegular, size: 14)
    static let subtitleItalic = Font.custom(sansItalic, size: 14)
    static let metadata = Font.custom(monoRegular, size: 12)
    static let timestamp = Font.custom(monoRegular, size: 13)
    static let tabLabel = Font.custom(monoBold, size: 10)
    static let inversionLabel = Font.custom(monoBold, size: 10)
    static let trackNumber = Font.custom(monoRegular, size: 13)
}
