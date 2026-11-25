import Foundation
import GhosttyKit
@testable import Macterm
import Testing

@MainActor
struct ConfirmCloseSurfaceTests {
    /// The raw values are ghostty's own `ConfirmCloseSurface` tag names, what
    /// `ghostty_config_get` gives for the key, so a rename is a wire break.
    @Test
    func the_values_are_ghosttys_own() {
        #expect([ConfirmCloseSurface.false, .true, .always].map(\.rawValue) == ["false", "true", "always"])
        #expect(ConfirmCloseSurface.key.name == "confirm-close-surface")
    }

    @Test
    func an_unset_or_unknown_value_is_ghosttys_default() {
        #expect(ConfirmCloseSurface.resolve(configValue: nil) == .true)
        #expect(ConfirmCloseSurface.resolve(configValue: "") == .true)
        #expect(ConfirmCloseSurface.resolve(configValue: "sometimes") == .true)
        #expect(ConfirmCloseSurface.resolve(configValue: "false") == .false)
        #expect(ConfirmCloseSurface.resolve(configValue: "always") == .always)
    }

    @Test
    func only_true_judges_the_state_of_a_pane() {
        #expect([ConfirmCloseSurface.false, .true, .always].filter(\.judgesPaneState) == [.true])
    }

    /// Each value read from a real, finalized config, through the key's
    /// own shape.
    @Test(arguments: ["false", "true", "always"])
    func the_key_reads_from_a_loaded_config(value: String) throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-confirm-close-\(UUID().uuidString).conf")
        try "confirm-close-surface = \(value)\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        #expect(ConfirmCloseSurface.resolve(configValue: ConfirmCloseSurface.key.read(from: config)).rawValue == value)
    }
}
