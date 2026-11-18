import Foundation
@testable import Macterm
import Sparkle
import Testing

/// `UpdatePolicy` against a real `SPUUpdater` and Sparkle's settings store.
/// Each test makes a bundle with its own identifier, so Sparkle writes to a
/// defaults domain of its own and never to the domain of the test host.
@MainActor
struct UpdatePolicyTests {
    @Test
    func enforce_turns_on_downloads_that_old_defaults_turned_off() throws {
        let host = try TemporaryHostBundle()
        defer { host.remove() }

        // A user who switched off "Update automatically" before the toggle
        // was removed. The updater is never started, so it checks nothing.
        let updater = SPUUpdater(
            hostBundle: host.bundle,
            applicationBundle: host.bundle,
            userDriver: SPUStandardUserDriver(hostBundle: host.bundle, delegate: nil),
            delegate: nil
        )
        updater.automaticallyDownloadsUpdates = false
        updater.automaticallyChecksForUpdates = false
        #expect(!SPUUpdaterSettings(hostBundle: host.bundle).automaticallyDownloadsUpdates)

        UpdatePolicy.enforce(on: updater)

        // A fresh reader sees the forced values in the defaults.
        let after = SPUUpdaterSettings(hostBundle: host.bundle)
        #expect(after.automaticallyDownloadsUpdates)
        #expect(after.automaticallyChecksForUpdates)
        #expect(host.defaults.bool(forKey: "SUAutomaticallyUpdate"))
        #expect(host.defaults.bool(forKey: "SUEnableAutomaticChecks"))
    }

    @Test
    func app_info_plist_allows_automatic_downloads() throws {
        // Sparkle ignores `automaticallyDownloadsUpdates` when the bundle does
        // not allow automatic updates, so `UpdatePolicy` depends on this key.
        let plist = try #require(NSDictionary(contentsOf: repoRoot().appendingPathComponent("Macterm/Info.plist")))
        #expect(plist["SUAllowsAutomaticUpdates"] as? Bool == true)
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(plist["SUScheduledCheckInterval"] as? Int == 86400)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

/// A bundle on disk with an `Info.plist` that allows automatic updates, and the
/// defaults domain that Sparkle uses for it.
private struct TemporaryHostBundle {
    let url: URL
    let identifier: String
    let bundle: Bundle
    let defaults: UserDefaults

    init() throws {
        identifier = IsolatedDefaults.makeSuiteName()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(identifier).app", isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "UpdatePolicyHost",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "SUAllowsAutomaticUpdates": true,
        ]
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        bundle = try #require(Bundle(url: url))
        defaults = try #require(UserDefaults(suiteName: identifier))
    }

    func remove() {
        defaults.removePersistentDomain(forName: identifier)
        try? FileManager.default.removeItem(at: url)
    }
}
