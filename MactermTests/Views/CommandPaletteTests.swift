@testable import Macterm
import Testing

/// What the palette panel shows under its field (`CommandPalettePanel.showsResults`).
@MainActor
struct CommandPaletteTests {
    @Test
    func an_input_screen_with_no_row_and_no_notice_is_the_field_alone() {
        #expect(!CommandPalettePanel.showsResults(isInput: true, hasRows: false, hasNotice: false))
    }

    @Test
    func an_input_screen_shows_its_completions_and_its_refusal() {
        #expect(CommandPalettePanel.showsResults(isInput: true, hasRows: true, hasNotice: false))
        #expect(CommandPalettePanel.showsResults(isInput: true, hasRows: false, hasNotice: true))
    }

    @Test
    func every_other_screen_always_shows_its_results() {
        #expect(CommandPalettePanel.showsResults(isInput: false, hasRows: false, hasNotice: false))
        #expect(CommandPalettePanel.showsResults(isInput: false, hasRows: true, hasNotice: true))
    }
}
