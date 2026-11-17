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
/// panes (Notifications, Accessibility): a 14 pt semibold glyph on a 26 pt
/// tile, an 11 pt gap to the text, the top of the tile at the top of the title.
struct SettingsInfoBlock<Content: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            SettingsInfoTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                content
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// The icon of an info block: the glyph in white, centered on a tile of the
/// tint, as in System Settings. The tile is the same size in every pane, so
/// the text column starts at the same x in every pane, whatever the width of
/// the glyph.
struct SettingsInfoTile: View {
    static let size: CGFloat = 26

    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.size, height: Self.size)
            .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}
