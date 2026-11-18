import Foundation
import GhosttyKit
@testable import Macterm
import Testing

/// `GhosttyApp.readThemeSideColors` reads one side of a `light:X,dark:Y`
/// theme from a real, finalized libghostty config, the way
/// `GhosttyApp.splitThemeColors` builds it: the user's config, then
/// `ThemeResolver.sideLayer` last.
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

    /// A finalized config from `files`, loaded in order.
    private func makeConfig(_ files: [String]) throws -> ghostty_config_t {
        let config = try #require(ghostty_config_new())
        for file in files {
            ghostty_config_load_file(config, file)
        }
        ghostty_config_finalize(config)
        return config
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
        let layer = try write("layer", ThemeResolver.sideLayer(split.dark))
        let config = try makeConfig([split.user, layer])
        defer { ghostty_config_free(config) }

        let colors = try #require(GhosttyApp.readThemeSideColors(from: config))
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
        let layer = try write("layer", ThemeResolver.sideLayer(split.light))
        let config = try makeConfig([split.user, layer])
        defer { ghostty_config_free(config) }

        let colors = try #require(GhosttyApp.readThemeSideColors(from: config))
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
        let layer = try write("layer", ThemeResolver.sideLayer(missing))
        let config = try makeConfig([split.user, layer])
        defer { ghostty_config_free(config) }

        #expect(GhosttyApp.readThemeSideColors(from: config) == nil)
    }
}
