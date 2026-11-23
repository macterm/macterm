import Foundation

/// Resolves ghostty's `theme = light:X,dark:Y` split syntax for Macterm's own
/// chrome (window, sidebar, palette — everything driven by `MactermTheme`).
///
/// libghostty applies the active color scheme only to the terminal *surface* at
/// render time (`ghostty_surface_set_color_scheme`); the surface re-resolves a
/// split on its own when the OS appearance changes. But the config object's
/// color getters (`ghostty_config_get("background")`, palette, …) always
/// resolve a split to the `light:` side and never consult the OS appearance,
/// and the raw `theme` value isn't readable back through the C API. So for the
/// chrome — which derives from those getters — Macterm picks the side itself
/// and has libghostty load it as a plain theme (`sideLayer`). A plain (non-split)
/// `theme` resolves correctly through libghostty's getters already, so the
/// chrome falls back to them in that case. (Issue #38.)
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

    /// Given the user's effective `theme` value, return the single theme name
    /// to force for `scheme`, or nil when the value isn't a light/dark split
    /// (libghostty handles plain themes correctly on its own).
    ///
    /// ghostty's split syntax is a comma-separated list of `key:value` pairs
    /// where keys are `light`/`dark`. Order is irrelevant. A value with no
    /// `light:`/`dark:` keys is a plain theme name (which may itself contain
    /// no colon, or be a path) and returns nil.
    static func resolve(themeValue: String, scheme: Scheme) -> String? {
        let trimmed = themeValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var light: String?
        var dark: String?
        for part in trimmed.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "light": light = value
            case "dark": dark = value
            default: continue
            }
        }

        // Only a real split (at least one recognized key) is ours to resolve.
        guard light != nil || dark != nil else { return nil }
        switch scheme {
        case .light: return light ?? dark
        case .dark: return dark ?? light
        }
    }

    /// The last layer of a config that reads one side of a split: a plain
    /// `theme` replaces the split. libghostty loads the theme first and puts
    /// every other key of the config over it, as it does for the side in use
    /// (`GhosttyApp.splitThemeColors`).
    static func sideLayer(_ side: String) -> String {
        "theme = \(side)\n"
    }

    /// The effective `theme` value of a config whose root files load in the
    /// order of `rootPaths`, as libghostty merges it: the root files, then
    /// each `config-file` include after all of them, in the order libghostty
    /// queues the includes (`loadRecursiveFiles`). An include loads one time,
    /// a file that `read` cannot read is skipped, and the last `theme` line
    /// wins. Nil when no line sets a theme, and when a `config-file` line
    /// with no value clears the queue (the merge is then not certain).
    static func themeValue(rootPaths: [String], read: (String) -> String?) -> String? {
        var theme: String?
        var queue: [String] = []
        func load(_ path: String) -> Bool {
            guard let text = read(path) else { return true }
            let base = (path as NSString).deletingLastPathComponent
            for (key, value) in entries(inConfigText: text) {
                switch key {
                case "theme":
                    if !value.isEmpty { theme = unquoted(value) }
                case "config-file":
                    guard !value.isEmpty else { return false }
                    var include = value.hasPrefix("?") ? String(value.dropFirst()) : value
                    include = unquoted(include)
                    if !include.isEmpty { queue.append(includePath(include, base: base)) }
                default:
                    continue
                }
            }
            return true
        }
        for path in rootPaths {
            guard load(path) else { return nil }
        }
        var loaded: Set<String> = []
        var index = 0
        while index < queue.count {
            let path = queue[index]
            index += 1
            guard loaded.insert(path).inserted else { continue }
            guard load(path) else { return nil }
        }
        return theme
    }

    /// The `key = value` lines of ghostty config text, in order. Comments
    /// (`#`) and blank lines are skipped.
    private static func entries(inConfigText text: String) -> [(key: String, value: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[line.startIndex ..< eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return (key, value)
        }
    }

    /// `value` without one matched pair of surrounding double quotes.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// The absolute path of a `config-file` value, as libghostty expands it
    /// (`Path.expand`): an absolute path stays, `~/` is the home directory,
    /// and any other path is relative to the directory of the file that
    /// names it, with its symbolic links resolved.
    private static func includePath(_ value: String, base: String) -> String {
        if value.hasPrefix("/") { return value }
        if value.hasPrefix("~/") { return (value as NSString).expandingTildeInPath }
        return URL(fileURLWithPath: (base as NSString).appendingPathComponent(value))
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}
