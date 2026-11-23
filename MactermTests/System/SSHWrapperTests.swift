import Foundation
@testable import Macterm
import Testing

struct SSHWrapperTests {
    // MARK: - The cases shared with the Zig `macterm ssh`

    /// `server/src/cli/fixtures/ssh.json`: `ssh.zig` reads the same file, so
    /// that the two copies of the rules stay equal (design 011 §2, no FFI).
    private struct Fixtures: Decodable {
        struct Destination: Decodable { var dump: String
            var destination: String?
        }

        struct DestinationArgv: Decodable { var ssh: String
            var args: [String]
            var argv: [String]
        }

        struct Relayed: Decodable { var captured: [String]
            var args: [String]
        }

        struct Exec: Decodable { var ssh: String
            var term: String?
            var args: [String]
            var argv: [String]
        }

        struct Install: Decodable {
            var ssh: String
            var controlPath: String
            var args: [String]
            var verbose: Bool
            var argv: [String]
        }

        struct VersionKey: Decodable { var source: String
            var key: String
        }

        struct Cache: Decodable {
            var text: String
            var destination: String
            var version: String
            var contains: Bool
            var updated: String
        }

        var destination: [Destination]
        var destinationArgv: [DestinationArgv]
        var relayed: [Relayed]
        var exec: [Exec]
        var install: [Install]
        var versionKey: [VersionKey]
        var cache: [Cache]
    }

    static let cliFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // System
        .deletingLastPathComponent() // MactermTests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("server/src/cli")

    private static func fixtures() throws -> Fixtures {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixtures.self, from: Data(contentsOf: cliFolder.appendingPathComponent("fixtures/ssh.json")))
    }

    @Test
    func the_rules_pass_the_shared_fixtures() throws {
        let f = try Self.fixtures()
        #expect(!f.destination.isEmpty)
        for c in f.destination {
            #expect(SSHWrapper.parseDestination(configDump: c.dump) == c.destination, "\(c.dump)")
        }
        for c in f.destinationArgv {
            #expect(SSHWrapper.destinationArgv(ssh: c.ssh, sshArgs: c.args) == c.argv)
        }
        for c in f.relayed {
            #expect(SSHWrapper.relayedArguments(c.captured) == c.args)
        }
        for c in f.exec {
            #expect(SSHWrapper.execArgv(ssh: c.ssh, term: c.term, sshArgs: c.args) == c.argv)
        }
        for c in f.install {
            #expect(SSHWrapper.installArgv(ssh: c.ssh, controlPath: c.controlPath, sshArgs: c.args, verbose: c.verbose) == c.argv)
        }
        for c in f.versionKey {
            #expect(SSHWrapper.versionKey(source: Data(c.source.utf8)) == c.key)
        }
        for c in f.cache {
            #expect(SSHWrapper.cacheContains(cacheText: c.text, destination: c.destination, version: c.version) == c.contains)
            #expect(SSHWrapper.cacheUpdating(cacheText: c.text, destination: c.destination, version: c.version) == c.updated)
        }
    }

    /// The Zig CLI embeds the entry as text. It must be the entry of the
    /// pinned GhosttyKit, which `mise run setup` puts in
    /// `Macterm/Resources/terminfo`: after a pin that changes it, write the
    /// file again with `infocmp -x xterm-ghostty`, without its first line.
    @Test
    func the_embedded_terminfo_is_the_bundled_entry() throws {
        let resources = Self.cliFolder
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Macterm/Resources/terminfo")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHWrapper.infocmpPath)
        process.arguments = SSHWrapper.sourceArgv()
        process.environment = ["TERMINFO": resources.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        // The first line is a comment with the path of the database.
        let source = String(decoding: out, as: UTF8.self).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let embedded = try String(contentsOf: Self.cliFolder.appendingPathComponent("terminfo/xterm-ghostty.terminfo"), encoding: .utf8)
        #expect(source.count == 2)
        #expect(source.first?.hasPrefix("#") == true)
        #expect(source.last.map(String.init) == embedded)
    }

    @Test
    func user_arguments_undo_exec_argv() {
        let typed = ["-p", "2222", "prod"]
        for term in ["xterm-ghostty", "xterm-256color", nil] {
            let argv = SSHWrapper.execArgv(ssh: "ssh", term: term, sshArgs: typed)
            #expect(SSHWrapper.userArguments(fromExecArguments: Array(argv.dropFirst())) == typed)
        }
        // An older wrapper passed the relay's `--` on; it goes when nothing
        // after it needs it.
        #expect(SSHWrapper.userArguments(fromExecArguments: SSHWrapper.forwardingOptions(term: "xterm-ghostty") + ["--", "prod"])
            == ["prod"])
        #expect(SSHWrapper.userArguments(fromExecArguments: ["--", "-p", "2222", "prod"]) == ["--", "-p", "2222", "prod"])
        // Options that aren't exactly the wrapper's are the user's.
        #expect(SSHWrapper.userArguments(fromExecArguments: ["-o", "SetEnv=TERM=dumb", "prod"]) == ["-o", "SetEnv=TERM=dumb", "prod"])
        #expect(SSHWrapper.userArguments(fromExecArguments: ["--"]) == ["--"])
    }

    @Test
    func install_script_matches_ghostty_ssh() {
        // ghostty-org/ghostty#15061 and #15112: compile into ~/.terminfo
        // (`-o`, so a tic that runs as root never writes the system
        // database), then check that infocmp finds the entry.
        #expect(
            SSHWrapper.installScript(verbose: false)
                == "sh -c 'tic -x -o ~/.terminfo - 2>/dev/null && infocmp -x xterm-ghostty >/dev/null 2>&1'"
        )
        // Verbose keeps tic's stderr — the commonest failure — visible.
        #expect(
            SSHWrapper.installScript(verbose: true)
                == "sh -c 'tic -x -o ~/.terminfo - && infocmp -x xterm-ghostty >/dev/null'"
        )
    }

    @Test
    func install_script_survives_non_posix_login_shells() {
        // sshd hands the remote command to the LOGIN shell, so the script
        // must ship as `sh -c '<single-quote-free single-line script>'` —
        // the HostCommands wire rule. Sent bare, a nushell login shell rejects
        // `2>&1` and the install always fails; measured against a real sshd.
        for verbose in [true, false] {
            let command = SSHWrapper.installScript(verbose: verbose)
            #expect(command.hasPrefix("sh -c '"))
            #expect(command.hasSuffix("'"))
            let inner = command.dropFirst("sh -c '".count).dropLast()
            #expect(!inner.contains("'"))
            #expect(!inner.contains("\n"))
        }
    }

    // MARK: - shared contract with the app side

    @Test
    func entry_name_matches_remote_terminfo() {
        // One promise about what our pinned libghostty supports, whether the
        // ssh is user-typed (SSHWrapper) or Macterm-owned (RemoteTerminfo).
        #expect(SSHWrapper.entryName == RemoteTerminfo.entryName)
        #expect(SSHWrapper.entryName == "xterm-ghostty")
    }

    @Test
    func source_argv_keeps_extended_capabilities() {
        // `-x` on infocmp must match the `-x` the remote tic gets, or the
        // Tc/RGB capabilities silently drop out of the installed entry.
        #expect(SSHWrapper.sourceArgv() == ["-x", "xterm-ghostty"])
        #expect(SSHWrapper.installScript(verbose: false).contains("tic -x -o "))
    }

    // MARK: - bundled DB resolution

    @Test
    func bundled_db_resolves_beside_the_binary() {
        let db = SSHWrapper.bundledTerminfoDirectory(
            executablePath: "/Applications/Macterm.app/Contents/Resources/bin/macterm",
            exists: { $0 == "/Applications/Macterm.app/Contents/Resources/terminfo/78/xterm-ghostty" }
        )
        #expect(db == "/Applications/Macterm.app/Contents/Resources/terminfo")
    }

    @Test
    func bundled_db_requires_the_hashed_entry_itself() {
        // A present directory without the entry (half-copied bundle) must
        // fall through to the inherited environment, not pin a dead TERMINFO.
        let db = SSHWrapper.bundledTerminfoDirectory(
            executablePath: "/Applications/Macterm.app/Contents/Resources/bin/macterm",
            exists: { $0 == "/Applications/Macterm.app/Contents/Resources/terminfo" }
        )
        #expect(db == nil)
    }

    // MARK: - install cache

    @Test
    func version_key_is_stable_and_content_addressed() {
        let a = SSHWrapper.versionKey(source: Data("entry-v1".utf8))
        let b = SSHWrapper.versionKey(source: Data("entry-v1".utf8))
        let c = SSHWrapper.versionKey(source: Data("entry-v2".utf8))
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 16)
    }
}
