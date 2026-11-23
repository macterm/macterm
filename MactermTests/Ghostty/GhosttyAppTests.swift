import Foundation
import GhosttyKit
@testable import Macterm
import Testing

/// `GhosttyApp.readThemeSideColors` reads one side of a `light:X,dark:Y`
/// theme from a real, finalized libghostty config, the way
/// `GhosttyApp.splitThemeColors` builds it: the user's config, then
/// `ThemeResolver.sideLayer` last, against the same config with no side
/// layer.
@MainActor
struct GhosttyAppTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("macterm-theme-side-\(UUID().uuidString)", isDirectory: true)

    /// Writes `text` to `name` in the test's directory and gives its path.
    private func write(_ name: String, _ text: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// A finalized config from `files`, loaded in order, then their
    /// `config-file` includes, then `last`, as `GhosttyApp.buildConfig` loads.
    private func makeConfig(_ files: [String], last: String? = nil) throws -> ghostty_config_t {
        let config = try #require(ghostty_config_new())
        for file in files {
            ghostty_config_load_file(config, file)
        }
        ghostty_config_load_recursive_files(config)
        if let last { ghostty_config_load_file(config, last) }
        ghostty_config_finalize(config)
        return config
    }

    /// The colors of the side layer over `user`, nil when the read refuses.
    private func readSide(_ side: String, over user: String) throws -> GhosttyApp.ResolvedColors? {
        let layer = try write("layer", ThemeResolver.sideLayer(side))
        let baseline = try makeConfig([user])
        defer { ghostty_config_free(baseline) }
        let config = try makeConfig([user], last: layer)
        defer { ghostty_config_free(config) }
        return GhosttyApp.readThemeSideColors(from: config, baseline: baseline)
    }

    /// Whether the side layer `side` over `user` gives the colors that
    /// libghostty merges for `user` with no conditional state.
    private func readsTheLightSide(_ side: String, over user: String) throws -> Bool {
        let colors = try #require(try readSide(side, over: user))
        let baseline = try makeConfig([user])
        defer { ghostty_config_free(baseline) }
        return GhosttyApp.readsTheLightSide(colors, baseline: baseline)
    }

    private func rgb(_ hex: UInt32) -> GhosttyApp.ResolvedColors.RGB {
        .init(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF))
    }

    /// Two theme files and a user config that names them as a pair and sets
    /// one palette entry of its own.
    private func makeSplit(paletteOverride: String = "palette = 1=#abcdef") throws -> (light: String, dark: String, user: String) {
        let light = try write("Light Side", "background = #f0f0f0\npalette = 0=#101010\npalette = 1=#111111\n")
        let dark = try write("Dark Side", "background = #202020\npalette = 0=#303030\npalette = 1=#313131\n")
        let user = try write("config", "theme = light:\(light),dark:\(dark)\n\(paletteOverride)\n")
        return (light, dark, user)
    }

    @Test
    func theSideLayerReadsTheDarkSideWithTheUsersColorKeysOverIt() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = try makeSplit()
        let colors = try #require(try readSide(split.dark, over: split.user))
        #expect(colors.background == rgb(0x202020))
        #expect(colors.palette[0] == rgb(0x303030))
        // A color key of the user's config wins over the theme, as libghostty
        // merges it for the side in use.
        #expect(colors.palette[1] == rgb(0xABCDEF))
    }

    @Test
    func theSideLayerReadsTheLightSide() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = try makeSplit(paletteOverride: "")
        let colors = try #require(try readSide(split.light, over: split.user))
        #expect(colors.background == rgb(0xF0F0F0))
        #expect(colors.palette[0] == rgb(0x101010))
        #expect(colors.palette[1] == rgb(0x111111))
    }

    /// libghostty keeps its default colors when it cannot load a theme. They
    /// are not the side's colors, so the read gives nothing.
    @Test
    func aSideThatDoesNotLoadReadsNothing() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = try makeSplit()
        let missing = directory.appendingPathComponent("No Such Theme").path
        #expect(try readSide(missing, over: split.user) == nil)
    }

    /// A bad line in the side's theme file leaves a default color in place.
    @Test
    func aBadLineInTheSideReadsNothing() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = try makeSplit()
        let broken = try write("Broken Dark", "background = #202020\npalette = 4=zzz\n")
        #expect(try readSide(broken, over: split.user) == nil)
    }

    /// A diagnostic of the user's own config is in both configs, so it does
    /// not stop the read.
    @Test
    func aDiagnosticOfTheUsersConfigDoesNotStopTheRead() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = try makeSplit(paletteOverride: "window-theme = bogus\nno-such-key = 1")
        let colors = try #require(try readSide(split.dark, over: split.user))
        #expect(colors.background == rgb(0x202020))
    }

    /// A pair set in an included file: Macterm reads it from the include,
    /// libghostty agrees on the light side, and the dark side has the
    /// user's color key over it.
    @Test
    func aPairInAnIncludeReadsBothSides() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = try makeSplit()
        let included = try write("included.conf", "theme = light:\(split.light),dark:\(split.dark)\n")
        let user = try write("root", "config-file = included.conf\ntheme = Root Theme\npalette = 1=#abcdef\n")
        let value = try #require(ThemeResolver.themeValue(rootPaths: [user]) {
            try? String(contentsOfFile: $0, encoding: .utf8)
        })
        let light = try #require(ThemeResolver.resolve(themeValue: value, scheme: .light))
        let dark = try #require(ThemeResolver.resolve(themeValue: value, scheme: .dark))
        #expect(light == split.light)
        #expect(try readsTheLightSide(light, over: user))
        let colors = try #require(try readSide(dark, over: user))
        #expect(colors.background == rgb(0x202020))
        #expect(colors.palette[1] == rgb(0xABCDEF))
    }

    /// A theme value that is not the one libghostty loaded fails the check,
    /// so the preview shows one icon.
    @Test
    func aWrongThemeValueFailsTheLightSideCheck() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = try makeSplit()
        let other = try write("Other Light", "background = #0a0b0c\n")
        #expect(try readsTheLightSide(split.light, over: split.user))
        #expect(try !readsTheLightSide(other, over: split.user))
    }
}
