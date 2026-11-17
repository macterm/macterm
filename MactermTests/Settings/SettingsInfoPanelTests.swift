import AppKit
@testable import Macterm
import SwiftUI
import Testing

/// The text of every block at the top of a Settings pane starts at the same x,
/// whatever glyph the block has. The glyphs have different natural widths, so
/// this measures the laid-out views, not the constants.
@MainActor
struct SettingsInfoPanelTests {
    /// The glyph of each info panel and of the General banners.
    static let symbols = [
        "folder", // Projects
        "rectangle.bottomthird.inset.filled", // Quick Terminal
        "widget.small", // Widgets
        "key", // Password Manager
        "apple.intelligence", // Intelligence
        "puzzlepiece.extension", // Extensions
        "exclamationmark.triangle.fill", // Full Disk Access and notification banners
    ]

    @Test
    func every_glyph_fits_in_the_box() {
        for symbol in Self.symbols {
            let glyph = NSHostingView(rootView: Image(systemName: symbol).font(.system(size: 14, weight: .semibold)))
            #expect(glyph.fittingSize.width <= SettingsInfoTile.boxWidth, "\(symbol)")
        }
    }

    @Test(arguments: [SettingsInfoIconStyle.box, .tile])
    func the_text_starts_at_the_same_x_in_every_block(style: SettingsInfoIconStyle) {
        let expectedIcon = style == .box ? SettingsInfoTile.boxWidth : SettingsInfoTile.tileSize
        var heights: Set<CGFloat> = []
        for symbol in Self.symbols {
            let tile = NSHostingView(rootView: SettingsInfoTile(symbol: symbol, style: style))
            #expect(tile.fittingSize.width == expectedIcon, "\(symbol)")

            let marker = TextOriginMarker()
            let block = NSHostingView(rootView: SettingsInfoBlock(symbol: symbol, style: style) {
                Text(verbatim: "Title")
                    .background(alignment: .topLeading) { marker }
                Text(verbatim: "A caption that wraps onto a second line at this width, as a pane caption does.")
            }
            .frame(width: 480))
            block.frame.size = block.fittingSize
            block.layoutSubtreeIfNeeded()
            let x = marker.view.convert(NSPoint.zero, to: block).x
            #expect(x == expectedIcon + 11, "\(symbol)")
            heights.insert(block.fittingSize.height)
        }
        #expect(heights.count == 1, "\(heights)")
    }
}

/// A zero-height AppKit view at the leading edge of the text column, which a
/// test can read the frame of after layout.
private struct TextOriginMarker: NSViewRepresentable {
    let view = NSView()

    func makeNSView(context _: Context) -> NSView {
        view
    }

    func updateNSView(_: NSView, context _: Context) {}
    func sizeThatFits(_: ProposedViewSize, nsView _: NSView, context _: Context) -> CGSize? {
        .zero
    }
}
