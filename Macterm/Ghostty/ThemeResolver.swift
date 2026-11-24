import Foundation

/// Resolves ghostty's `theme = light:X,dark:Y` split syntax for Macterm's own
/// chrome (window, sidebar, palette — everything driven by `MactermTheme`).
///
/// libghostty applies the active color scheme only to the terminal *surface* at
/// render time (`ghostty_surface_set_color_scheme`); the surface re-resolves a
/// split on its own when the OS appearance changes. But the config object's
/// color getters (`ghostty_config_get("background")`, palette, …) always
/// resolve a split to the `light:` side and never consult the OS appearance.
/// So for the chrome — which derives from those getters — Macterm takes the
/// two sides from libghostty (`Sides`) and has libghostty load one side as a
/// plain theme (`sideLayer`). A plain (non-split) `theme` resolves correctly
/// through libghostty's getters already, so the chrome falls back to them in
/// that case. (Issue #38.)
enum ThemeResolver {
    /// The side of a `light:`/`dark:` split to pick.
    enum Scheme {
        case light
        case dark
    }

    /// The *system* scheme from raw inputs (pure, for tests). A pinned app's
    /// effective appearance echoes our own `preferredColorScheme` (issue
    /// #144), so it's trusted only unpinned; otherwise the OS-maintained
    /// `AppleInterfaceStyle` global default ("Dark"/absent) decides.
    static func systemScheme(
        appHasAppearanceOverride: Bool,
        effectiveAppearanceIsDark: Bool,
        globalInterfaceStyle: String?
    ) -> Scheme {
        guard appHasAppearanceOverride else {
            return effectiveAppearanceIsDark ? .dark : .light
        }
        return globalInterfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame ? .dark : .light
    }

    /// The two sides of the `theme` value that libghostty merged
    /// (`GhosttyConfigKey.theme`). A plain theme has the same name on both
    /// sides.
    struct Sides: Equatable {
        var light: String
        var dark: String

        var areDifferent: Bool {
            light != dark
        }
    }

    /// The last layer of a config that reads one side of a split: a plain
    /// `theme` replaces the split. libghostty loads the theme first and puts
    /// every other key of the config over it, as it does for the side in use
    /// (`GhosttyApp.splitThemeColors`).
    static func sideLayer(_ side: String) -> String {
        "theme = \(side)\n"
    }
}
