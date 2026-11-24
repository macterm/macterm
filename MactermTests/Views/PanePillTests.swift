import AppKit
@testable import Macterm
import SwiftUI
import Testing

/// Every badge in a pane's corner has the same height. This measures the
/// laid-out views, so a badge with its own chrome, font or icon fails.
@MainActor
struct PanePillTests {
    static func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }

    static var badges: [(String, CGFloat)] {
        [
            ("Read-Only", height(ModePill(title: "Read-Only", systemImage: "eye", help: "") {})),
            ("Copy Mode", height(ModePill(title: "Copy Mode", systemImage: "character.cursor.ibeam", help: "") {})),
            ("Outdated", height(ModePill(title: "Outdated", systemImage: "arrow.triangle.2.circlepath", help: "") {})),
            ("Zoomed", height(ZoomIndicator {})),
            ("Reconnecting", height(RemoteLinkPill(badge: .reconnecting))),
            ("Connection Lost", height(RemoteLinkPill(badge: .lost))),
            ("Secure Input", height(SecureInputBadge())),
        ]
    }

    @Test
    func every_badge_has_the_same_height() {
        let badges = Self.badges
        let heights = Set(badges.map(\.1))
        #expect(heights.count == 1, "\(badges)")
    }

    static func size(_ view: some View) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    static func label(_ systemImage: String, reveal: CGFloat) -> some View {
        PanePillLabel(title: "Connection Lost", reveal: reveal) { Image(systemName: systemImage) }
    }

    /// At rest a pill shows its icon only: the label is at least
    /// `contentHeight` wide, and much narrower than its title.
    @Test
    func a_label_at_rest_is_its_icon_only() {
        let icons = ["eye", "character.cursor.ibeam", "lock.fill", "network.slash", "arrow.down.right.and.arrow.up.left"]
        for icon in icons {
            let width = Self.size(Self.label(icon, reveal: 0)).width
            #expect(width >= PanePill<EmptyView>.contentHeight, "\(icon)")
            #expect(width < PanePill<EmptyView>.contentHeight + 8, "\(icon)")
        }
    }

    /// The revealed title widens the label, step by step.
    @Test
    func the_revealed_title_widens_the_label() {
        let rest = Self.size(Self.label("network.slash", reveal: 0))
        let half = Self.size(Self.label("network.slash", reveal: 0.5))
        let shown = Self.size(Self.label("network.slash", reveal: 1))
        #expect(rest.width < half.width)
        #expect(half.width < shown.width)
        #expect(shown.width > rest.width + 40)
    }

    /// An open pill is as wide as its own title, with no room for another
    /// title: the open `Reconnecting` pill is narrower than the open
    /// `Connection Lost` pill.
    @Test
    func an_open_pill_is_as_wide_as_its_own_title() {
        let widths = ["Reconnecting", "Connection Lost"].map { title in
            Self.size(PanePillLabel(title: title, reveal: 1) {
                Image(systemName: "network.slash")
            }).width
        }
        #expect(widths[0] < widths[1], "\(widths)")
        let icon = Self.size(PanePillLabel(title: "Reconnecting", reveal: 0) {
            Image(systemName: "network.slash")
        }).width
        let text = Self.size(Text("Reconnecting").fixedSize()).width
        // The icon, the gap of 4 pt and the title: nothing more.
        #expect(abs(widths[0] - (icon + 4 + text)) < 1, "\(widths[0]) \(icon) \(text)")
    }

    /// An open pill whose title gets shorter keeps the width of the earlier
    /// title, so it stays under the pointer. A longer title still widens it.
    @Test
    func an_open_pill_keeps_the_width_of_an_earlier_title() {
        func width(_ title: String, held: [String]) -> CGFloat {
            Self.size(PanePillLabel(title: title, heldTitles: held, reveal: 1) {
                Image(systemName: "character.cursor.ibeam")
            }).width
        }
        #expect(width("Visual", held: ["Visual Block"]) == width("Visual Block", held: []))
        #expect(width("Visual Block", held: ["Visual"]) == width("Visual Block", held: []))
        #expect(width("Visual", held: []) < width("Visual Block", held: []))
        /// At rest a held title adds no width.
        func rest(held: [String]) -> CGFloat {
            Self.size(PanePillLabel(title: "Visual", heldTitles: held, reveal: 0) {
                Image(systemName: "character.cursor.ibeam")
            }).width
        }
        #expect(rest(held: ["Visual Block"]) == rest(held: []))
    }

    /// A pill highlights when its title changes in place: not at its first
    /// title, and not when the same title comes again.
    @Test
    func a_change_of_the_title_highlights_the_pill() {
        var change = PanePillChange()
        #expect(change.record("Copy Mode") == false)
        #expect(change.record("Copy Mode") == false)
        #expect(change.record("Visual") == true)
        #expect(change.record("Visual") == false)
        #expect(change.record("Copy Mode") == true)
        var remote = PanePillChange()
        #expect(remote.record("Reconnecting") == false)
        #expect(remote.record("Connection Lost") == true)
    }

    /// Every whole badge at rest (chrome, padding and icon, the spinner too)
    /// is near round: much narrower than a badge that shows its title.
    @Test
    func every_badge_at_rest_shows_no_title() {
        let rest: [(String, CGFloat)] = [
            ("Read-Only", Self.size(ModePill(title: "Read-Only", systemImage: "eye", help: "") {}).width),
            ("Zoomed", Self.size(ZoomIndicator {}).width),
            ("Reconnecting", Self.size(RemoteLinkPill(badge: .reconnecting)).width),
            ("Connection Lost", Self.size(RemoteLinkPill(badge: .lost)).width),
            ("Secure Input", Self.size(SecureInputBadge()).width),
        ]
        let height = Self.badges[0].1
        for (name, width) in rest {
            #expect(width < height * 2, "\(name): \(width)")
        }
    }
}
