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
}
