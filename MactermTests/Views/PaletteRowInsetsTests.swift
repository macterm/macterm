@testable import Macterm
import Testing

/// The palette's section header and its rows share one inset, so a header
/// label starts where the title of a row with no icon starts.
@MainActor
struct PaletteRowInsetsTests {
    @Test
    func textEdgeIsHighlightPlusContent() {
        #expect(PaletteRowInsets.text == PaletteRowInsets.highlight + PaletteRowInsets.content)
    }
}
