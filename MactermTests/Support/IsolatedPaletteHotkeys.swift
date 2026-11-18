import Foundation
@testable import Macterm

extension PaletteHotkeys {
    /// A keybind table that no other test sees: its own defaults suite
    /// (`IsolatedDefaults`), and no Carbon registration.
    static func isolated() -> PaletteHotkeys {
        PaletteHotkeys(defaults: IsolatedDefaults.make(), syncGlobalHotkeys: {})
    }
}
