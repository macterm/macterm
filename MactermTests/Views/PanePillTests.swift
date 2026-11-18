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
            ("Connection lost", height(RemoteLinkPill(badge: .lost))),
            ("Secure input", height(SecureInputBadge())),
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
        PanePillLabel(title: "Connection lost", reveal: reveal) { Image(systemName: systemImage) }
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

    /// The revealed title widens the label and keeps its height.
    @Test
    func the_revealed_title_widens_the_label() {
        let rest = Self.size(Self.label("network.slash", reveal: 0))
        let half = Self.size(Self.label("network.slash", reveal: 0.5))
        let shown = Self.size(Self.label("network.slash", reveal: 1))
        #expect(rest.width < half.width)
        #expect(half.width < shown.width)
        #expect(shown.width > rest.width + 40)
        #expect(rest.height == shown.height)
    }
}
