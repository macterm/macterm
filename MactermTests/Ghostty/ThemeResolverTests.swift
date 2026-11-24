import Foundation
@testable import Macterm
import Testing

struct ThemeResolverTests {
    // MARK: - resolve(themeValue:scheme:)

    @Test
    func split_picks_matching_side() {
        let value = "light:branch,dark:Builtin Tango Dark"
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .light) == "branch")
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .dark) == "Builtin Tango Dark")
    }

    @Test
    func split_order_does_not_matter() {
        let value = "dark:Builtin Tango Dark,light:branch"
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .light) == "branch")
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .dark) == "Builtin Tango Dark")
    }

    @Test
    func plain_theme_is_not_resolved() {
        #expect(ThemeResolver.resolve(themeValue: "Rose Pine", scheme: .dark) == nil)
        #expect(ThemeResolver.resolve(themeValue: "Builtin Tango Light", scheme: .light) == nil)
    }

    @Test
    func empty_is_not_resolved() {
        #expect(ThemeResolver.resolve(themeValue: "", scheme: .dark) == nil)
        #expect(ThemeResolver.resolve(themeValue: "   ", scheme: .light) == nil)
    }

    @Test
    func partial_split_falls_back_to_present_side() {
        #expect(ThemeResolver.resolve(themeValue: "dark:Tokyo Night", scheme: .light) == "Tokyo Night")
        #expect(ThemeResolver.resolve(themeValue: "light:Catppuccin", scheme: .dark) == "Catppuccin")
    }

    @Test
    func whitespace_around_pairs_is_trimmed() {
        let value = " light : branch , dark : Builtin Tango Dark "
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .light) == "branch")
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .dark) == "Builtin Tango Dark")
    }

    // MARK: - themeValue(rootPaths:read:)

    /// The theme value of `files` (path to text), loading `roots` in order.
    private func theme(_ roots: [String], _ files: [String: String]) -> String? {
        ThemeResolver.themeValue(rootPaths: roots) { files[$0] }
    }

    @Test
    func reads_theme_line() {
        let text = "font-size = 16\ntheme = light:branch,dark:Tango\nwindow-padding-x = 16\n"
        #expect(theme(["/c"], ["/c": text]) == "light:branch,dark:Tango")
    }

    @Test
    func last_theme_line_wins() {
        let text = "theme = Rose Pine\ntheme = light:branch,dark:Tango\n"
        #expect(theme(["/c"], ["/c": text]) == "light:branch,dark:Tango")
    }

    @Test
    func a_later_root_file_wins() {
        #expect(theme(["/a", "/b"], ["/a": "theme = A\n", "/b": "theme = B\n"]) == "B")
    }

    @Test
    func ignores_comments_and_blanks() {
        let text = "# theme = ignored\n\n  theme = Tokyo Night  \n"
        #expect(theme(["/c"], ["/c": text]) == "Tokyo Night")
    }

    @Test
    func strips_surrounding_quotes() {
        #expect(theme(["/c"], ["/c": "theme = \"Rose Pine\"\n"]) == "Rose Pine")
    }

    @Test
    func no_theme_line_returns_nil() {
        #expect(theme(["/c"], ["/c": "font-size = 16\n"]) == nil)
    }

    @Test
    func does_not_match_keys_that_contain_theme() {
        #expect(theme(["/c"], ["/c": "window-theme = dark\n"]) == nil)
    }

    @Test
    func a_root_file_that_cannot_be_read_is_skipped() {
        #expect(theme(["/a", "/missing"], ["/a": "theme = A\n"]) == "A")
    }

    @Test
    func an_include_sets_the_theme() {
        let files = [
            "/cfg/config": "font-size = 14\nconfig-file = theme.conf\n",
            "/cfg/theme.conf": "theme = light:A,dark:B\n",
        ]
        #expect(theme(["/cfg/config"], files) == "light:A,dark:B")
    }

    /// libghostty loads every include after all root files, so an include
    /// wins over a root line that comes after the `config-file` line, and
    /// over a later root file.
    @Test
    func an_include_loads_after_all_root_files() {
        let files = [
            "/a": "config-file = /inc\ntheme = Root A\n",
            "/b": "theme = Root B\n",
            "/inc": "theme = Included\n",
        ]
        #expect(theme(["/a", "/b"], files) == "Included")
    }

    @Test
    func includes_load_in_queue_order_with_nested_includes_last() {
        let files = [
            "/root": "config-file = /one\nconfig-file = /two\n",
            "/one": "theme = One\nconfig-file = /nested\n",
            "/two": "theme = Two\n",
            "/nested": "theme = Nested\n",
        ]
        #expect(theme(["/root"], files) == "Nested")
    }

    @Test
    func optional_and_quoted_includes_are_read() {
        let files = [
            "/root": "config-file = ?\"/my theme\"\n",
            "/my theme": "theme = Quoted\n",
        ]
        #expect(theme(["/root"], files) == "Quoted")
    }

    @Test
    func a_missing_include_is_skipped() {
        let files = ["/root": "theme = Root\nconfig-file = ?/none\n"]
        #expect(theme(["/root"], files) == "Root")
    }

    @Test
    func an_include_loads_one_time() {
        let files = [
            "/root": "config-file = /a\nconfig-file = /b\n",
            "/a": "theme = A\n",
            "/b": "theme = B\nconfig-file = /a\n",
        ]
        #expect(theme(["/root"], files) == "B")
    }

    @Test
    func a_tilde_include_is_under_the_home_directory() {
        let home = NSHomeDirectory()
        let files = ["/root": "config-file = ~/t.conf\n", home + "/t.conf": "theme = Home\n"]
        #expect(theme(["/root"], files) == "Home")
    }

    @Test
    func reads_crlf_lines() {
        let files = ["/root": "font-size = 14\r\nconfig-file = /inc\r\n", "/inc": "theme = CRLF\r\n"]
        #expect(theme(["/root"], files) == "CRLF")
    }

    /// libghostty resolves a relative include from the real directory of the
    /// file, so a `..` goes up from where a symbolic link points.
    @Test
    func a_relative_include_goes_up_from_the_real_directory() throws {
        let fm = FileManager.default
        let top = fm.temporaryDirectory.appendingPathComponent("macterm-include-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: top) }
        let real = top.appendingPathComponent("dotfiles/ghostty")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createDirectory(at: top.appendingPathComponent("dotfiles/shared"), withIntermediateDirectories: true)
        try fm.createDirectory(at: top.appendingPathComponent("config"), withIntermediateDirectories: true)
        let link = top.appendingPathComponent("config/ghostty")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        try "config-file = ../shared/theme.conf\n".write(
            to: real.appendingPathComponent("config"), atomically: true, encoding: .utf8
        )
        try "theme = Shared\n".write(
            to: top.appendingPathComponent("dotfiles/shared/theme.conf"), atomically: true, encoding: .utf8
        )
        let root = link.appendingPathComponent("config").path
        #expect(ThemeResolver.themeValue(rootPaths: [root]) { try? String(contentsOfFile: $0, encoding: .utf8) } == "Shared")
    }

    /// An empty `config-file` value clears libghostty's queue while it loads
    /// it. That merge is not read: the theme is not certain.
    @Test
    func an_empty_include_reads_nothing() {
        let files = ["/root": "theme = Root\nconfig-file =\n"]
        #expect(theme(["/root"], files) == nil)
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
