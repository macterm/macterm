import SwiftUI

/// The block at the top of a Settings pane, in the shape of the one at the
/// top of a System Settings pane: a symbol, the pane's name, and what the
/// whole pane is about, ending with a "Learn more…" link to the docs. The
/// sections below do not say it again, and a pane that has this block puts no
/// docs button on a section that it links.
struct SettingsInfoPanel: View {
    let symbol: String
    let title: String
    let caption: String
    let docs: DocsSection

    var body: some View {
        SettingsInfoBlock(symbol: symbol) {
            Text(title)
            Text(captionWithLink)
                .settingsSecondaryText()
        }
    }

    /// The caption, then the docs link as its own phrase, as System Settings
    /// ends its block with "Learn more…".
    private var captionWithLink: AttributedString {
        var text = AttributedString(caption)
        var link = AttributedString(String(localized: "Learn more…"))
        link.link = docs.url
        // Chinese puts no space after a full-width full stop.
        if let last = text.characters.last, !"。！？".contains(last) {
            text.append(AttributedString(" "))
        }
        text.append(link)
        return text
    }
}

/// The layout of every block at the top of a pane: the info panels and the
/// banners in General. Sizes measured in the header of the System Settings
/// panes (Notifications, Accessibility): a 14 pt semibold glyph, a 26 pt tile,
/// an 11 pt gap to the text.
struct SettingsInfoBlock<Content: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    var style: SettingsInfoIconStyle = .current
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: style == .tile ? .top : .firstTextBaseline, spacing: 11) {
            SettingsInfoTile(symbol: symbol, tint: tint, style: style)
            VStack(alignment: .leading, spacing: 2) {
                content
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// The two looks of the icon that issue 0328 shows Ethan side by side. The
/// switch is temporary: the merge keeps one look and removes this type.
enum SettingsInfoIconStyle: String {
    /// The glyph centered in a box as wide as the widest glyph, with no
    /// background, so that the text starts at the same x in every pane.
    case box
    /// The glyph in white on a tile of the tint, as in System Settings.
    case tile

    /// The defaults key `settingsInfoIconStyle` (`box` or `tile`) of a Debug
    /// build. A Release build shows `box`.
    static var current: Self {
        #if DEBUG
        Preferences.defaults.string(forKey: "settingsInfoIconStyle").flatMap(Self.init(rawValue:)) ?? .box
        #else
        .box
        #endif
    }
}

/// The icon of an info block. Every pane draws it at the same width, so the
/// text column starts at the same x in every pane.
struct SettingsInfoTile: View {
    /// The width of the widest glyph that a block uses at 14 pt semibold
    /// (`puzzlepiece.extension` and `rectangle.bottomthird.inset.filled`).
    /// `SettingsInfoPanelTests` measures each glyph against it.
    static let boxWidth: CGFloat = 21
    static let tileSize: CGFloat = 26

    let symbol: String
    var tint: Color = .accentColor
    var style: SettingsInfoIconStyle = .current

    var body: some View {
        let glyph = Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
        switch style {
        case .box:
            // A hidden line in the title's font gives the box the height and
            // the baseline of the title's first line, whatever the glyph's own
            // height. The glyph is centered on that line, so a tall glyph
            // (`key`) does not make its block taller than the others.
            Text(verbatim: " ")
                .hidden()
                .frame(width: Self.boxWidth)
                .overlay { glyph.foregroundStyle(tint) }
                .accessibilityHidden(true)
        case .tile:
            glyph
                .foregroundStyle(.white)
                .frame(width: Self.tileSize, height: Self.tileSize)
                .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
