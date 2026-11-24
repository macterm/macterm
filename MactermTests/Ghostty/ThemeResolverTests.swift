import Foundation
@testable import Macterm
import Testing

struct ThemeResolverTests {
    // MARK: - Sides

    @Test
    func sides_give_the_name_for_each_scheme() {
        let sides = ThemeResolver.Sides(light: "branch", dark: "Builtin Tango Dark")
        #expect(sides.side(.light) == "branch")
        #expect(sides.side(.dark) == "Builtin Tango Dark")
        #expect(sides.areDifferent)
    }

    @Test
    func a_plain_theme_has_one_side() {
        #expect(!ThemeResolver.Sides(light: "Rose Pine", dark: "Rose Pine").areDifferent)
    }

    // MARK: - systemScheme(appHasAppearanceOverride:effectiveAppearanceIsDark:globalInterfaceStyle:)

    @Test
    func unpinned_app_trusts_effective_appearance() {
        #expect(ThemeResolver.systemScheme(
            appHasAppearanceOverride: false, effectiveAppearanceIsDark: true, globalInterfaceStyle: nil
        ) == .dark)
        #expect(ThemeResolver.systemScheme(
            appHasAppearanceOverride: false, effectiveAppearanceIsDark: false, globalInterfaceStyle: "Dark"
        ) == .light)
    }

    @Test
    func pinned_app_ignores_its_own_effective_appearance() {
        // The latch in issue #144: the app pinned itself dark, the system went
        // back to light. The echoed effective appearance must lose to the
        // OS-maintained global default (absent = light).
        #expect(ThemeResolver.systemScheme(
            appHasAppearanceOverride: true, effectiveAppearanceIsDark: true, globalInterfaceStyle: nil
        ) == .light)
        #expect(ThemeResolver.systemScheme(
            appHasAppearanceOverride: true, effectiveAppearanceIsDark: false, globalInterfaceStyle: "Dark"
        ) == .dark)
    }

    @Test
    func interface_style_compares_case_insensitively() {
        #expect(ThemeResolver.systemScheme(
            appHasAppearanceOverride: true, effectiveAppearanceIsDark: false, globalInterfaceStyle: "dark"
        ) == .dark)
        #expect(ThemeResolver.systemScheme(
            appHasAppearanceOverride: true, effectiveAppearanceIsDark: false, globalInterfaceStyle: "Light"
        ) == .light)
    }

    @Test
    func theSideLayerIsAPlainThemeLine() {
        #expect(ThemeResolver.sideLayer("Builtin Tango Dark") == "theme = Builtin Tango Dark\n")
    }
}
