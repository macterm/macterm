@testable import Macterm
import Testing

/// The heading of a saved password's row (`SavedPasswordRow.heading`).
@MainActor
struct PasswordsSettingsTests {
    @Test
    func a_host_entry_names_its_host() {
        #expect(SavedPasswordRow.heading(PasswordEntryID(command: "sudo", prompt: "Password:", host: "me@prod:22"))
            == "sudo (me@prod:22)")
        #expect(SavedPasswordRow.heading(PasswordEntryID(command: "sudo", prompt: "Password:")) == "sudo")
    }
}
