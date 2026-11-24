import Foundation
@testable import Macterm
import Testing

struct RemotePaneDriverTests {
    @Test
    func a_line_of_macterm_starts_on_a_line_of_its_own_and_ends_with_cr_lf() {
        #expect(RemotePaneDriver.paneText("box refuses.\nPress a key.") == "\r\nbox refuses.\r\nPress a key.\r\n")
    }
}
