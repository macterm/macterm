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
        // Sizes measured in the header of the System Settings panes
        // (Notifications, Accessibility): a 26 pt icon, a 11 pt gap to the
        // text, the icon level with the title.
        HStack(alignment: .top, spacing: 11) {
            SettingsInfoTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(captionWithLink)
                    .settingsSecondaryText()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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

/// The icon of an info block: a glyph in a 26 pt frame, with no background. The banners in
/// General use it too, so that every block at the top of a pane looks the same.
struct SettingsInfoTile: View {
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
    }
}
