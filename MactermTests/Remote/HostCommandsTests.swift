import Foundation
@testable import Macterm
import Testing

struct HostCommandsTests {
    private func create() -> String {
        HostCommands.createProbeScript
    }

    /// The host scripts of the tree (`server/host/`).
    private func scripts() throws -> HostCommands.Scripts {
        let tree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/host", isDirectory: true)
        return try #require(HostCommands.Scripts.load(from: tree))
    }

    private func plain(_ directory: String) throws -> String {
        try #require(try scripts().plainCommand(directory: directory))
    }

    // MARK: - Round trips

    /// The folders that a round trip sends, relative to a home folder, and
    /// the folder that each must reach.
    private static let folders: [(sent: String, made: String?)] = [
        ("~", nil),
        ("~/a b", "a b"),
        ("~/it's", "it's"),
        ("~/$(touch pwned)", "$(touch pwned)"),
        ("~/`touch pwned`", "`touch pwned`"),
        ("~/back\\slash", "back\\slash"),
        ("~/\"q\" $HOME", "\"q\" $HOME"),
        ("~/ünï", "ünï"),
        ("~/semi;colon", "semi;colon"),
    ]

    /// A home folder with the folders of `folders`, and a `SHELL` that
    /// prints its physical folder.
    private struct Home {
        let url: URL
        let shell: String

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("hc-\(UUID().uuidString)")
            let home = base.appendingPathComponent("home", isDirectory: true)
            for folder in HostCommandsTests.folders.compactMap(\.made) {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            // The physical path, as `pwd -P` prints it: the temp folder is
            // under a symlink, and `resolvingSymlinksInPath` drops `/private`.
            let physical = try #require(realpath(home.path, nil))
            defer { free(physical) }
            url = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            shell = base.appendingPathComponent("pwd.sh").path
            try "#!/bin/sh\npwd -P\n".write(toFile: shell, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
        }

        func expected(_ made: String?) -> String {
            made.map { url.appendingPathComponent($0).path } ?? url.path
        }

        var environment: [String: String] {
            ["HOME": url.path, "SHELL": shell, "TERM": "dumb", "PATH": "/usr/bin:/bin"]
        }

        /// Make an empty file at `path` under the home folder.
        func makeFile(_ path: String) throws {
            try Data().write(to: url.appendingPathComponent(path))
        }

        /// No folder named `pwned` came from a command in a folder name.
        var nothingRan: Bool {
            !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("pwned").path)
                && !FileManager.default.fileExists(atPath: url.appendingPathComponent("pwned").path)
        }
    }

    private static func run(_ argv: [String], environment: [String: String], in folder: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test
    func the_create_probe_reaches_each_folder() throws {
        let home = try Home()
        for (sent, made) in Self.folders {
            let result = try Self.run(HostCommands.createProbeArgv(directory: sent), environment: home.environment, in: home.url)
            let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            #expect(lines.first == "ok", "\(sent)")
            #expect(lines.dropFirst().first == home.expected(made), "\(sent): \(result.output)")
        }
        #expect(home.nothingRan)
    }

    @Test
    func the_create_probe_falls_back_to_home_for_a_missing_or_hostile_folder() throws {
        let home = try Home()
        for sent in ["/no/such/folder", "~$(touch pwned)/x", "~`touch pwned`", "~a b/c", "/x;touch pwned"] {
            let result = try Self.run(HostCommands.createProbeArgv(directory: sent), environment: home.environment, in: home.url)
            let lines = result.output.split(separator: "\n").map(String.init)
            #expect(Array(lines.prefix(2)) == ["home", home.url.path], "\(sent)")
        }
        #expect(home.nothingRan)
    }

    @Test
    func a_tilde_name_is_never_evaluated_when_tr_cannot_run() throws {
        // The name check runs `tr`: when it fails, the name stays as it is.
        let home = try Home()
        var environment = home.environment
        environment["PATH"] = "/nonexistent"
        _ = try Self.run(HostCommands.createProbeArgv(directory: "~$(touch pwned)"), environment: environment, in: home.url)
        #expect(home.nothingRan)
    }

    @Test
    func the_git_probe_reaches_the_folder_or_exits_2() throws {
        let home = try Home()
        for (sent, _) in Self.folders {
            let result = try Self.run(HostCommands.gitProbeArgv(directory: sent), environment: home.environment, in: home.url)
            // Past the `cd`: no git (3) or no repository (4).
            #expect([3, 4].contains(result.status), "\(sent): \(result.status)")
        }
        for sent in ["~/gone", "/x;exit 0", "~$(touch pwned)"] {
            let result = try Self.run(HostCommands.gitProbeArgv(directory: sent), environment: home.environment, in: home.url)
            #expect(result.status == 2, "\(sent)")
        }
        #expect(home.nothingRan)
    }

    @Test(arguments: ["/bin/sh", "/bin/csh"])
    func the_plain_shell_starts_in_each_folder_under_a_login_shell(_ loginShell: String) throws {
        // sshd gives the command line to the user's login shell.
        let home = try Home()
        for (sent, made) in Self.folders {
            let result = try Self.run([loginShell, "-c", plain(sent)], environment: home.environment, in: home.url)
            #expect(Self.shown(result.output).split(separator: "\n").last.map(String.init) == home.expected(made), "\(sent)")
        }
        #expect(home.nothingRan)
    }

    @Test(arguments: ["/bin/sh", "/bin/csh"])
    func the_plain_shell_starts_in_home_for_a_hostile_folder(_ loginShell: String) throws {
        // The pane's ssh starts in the home folder, as this process does.
        let home = try Home()
        for sent in ["~$(touch pwned)/x", "~`touch pwned`", "~a b/c", "/x;touch pwned"] {
            let result = try Self.run([loginShell, "-c", plain(sent)], environment: home.environment, in: home.url)
            #expect(Self.shown(result.output).split(separator: "\n").last.map(String.init) == home.url.path, "\(sent)")
        }
        #expect(home.nothingRan)
    }

    @Test
    func a_tilde_with_a_user_name_reaches_that_users_home() throws {
        let home = try Home()
        let user = NSUserName()
        let real = try #require(realpath(FileManager.default.homeDirectory(forUser: user)?.path ?? "", nil))
        defer { free(real) }
        let expected = String(cString: real)
        let probe = try Self.run(HostCommands.createProbeArgv(directory: "~\(user)"), environment: home.environment, in: home.url)
        #expect(probe.output.split(separator: "\n").prefix(2).map(String.init) == ["ok", expected])
        for loginShell in ["/bin/sh", "/bin/csh"] {
            let result = try Self.run([loginShell, "-c", plain("~\(user)")], environment: home.environment, in: home.url)
            #expect(Self.shown(result.output).split(separator: "\n").last.map(String.init) == expected, "\(loginShell)")
        }
    }

    @Test(arguments: ["/bin/sh", "/bin/csh"])
    func the_plain_shell_says_when_the_folder_is_missing(_ loginShell: String) throws {
        let home = try Home()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = try ["-c", plain("/nonexistent;touch pwned")]
        process.environment = home.environment
        process.currentDirectoryURL = home.url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // One line from Macterm, none from the host's cd, then the shell.
        #expect(Self.shown(output) == "macterm: cannot cd to /nonexistent;touch pwned\n" + home.url.path + "\n")
        #expect(home.nothingRan)
    }

    /// What the pane shows of a plain shell's output: `PlainShell` removes
    /// the announcement of the shell's pid.
    private static func shown(_ output: String) -> String {
        var announcement = PlainShellAnnouncement()
        return String(decoding: announcement.consume(Data(output.utf8)), as: UTF8.self)
    }

    @Test(arguments: ["/bin/sh", "/bin/csh"])
    func the_plain_shell_announces_the_pid_of_the_login_shell(_ loginShell: String) throws {
        // The login shell prints its own pid: the announcement must name it,
        // because the close check asks the host about that pid (0494).
        let home = try Home()
        let shell = home.url.deletingLastPathComponent().appendingPathComponent("pid.sh").path
        try "#!/bin/sh\necho $$\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
        var environment = home.environment
        environment["SHELL"] = shell
        let result = try Self.run([loginShell, "-c", plain("~")], environment: environment, in: home.url)
        var announcement = PlainShellAnnouncement()
        let shown = String(decoding: announcement.consume(Data(result.output.utf8)), as: UTF8.self)
        let pid = try #require(announcement.pid)
        #expect(shown == "\(pid)\n")
    }

    private static func shellState(_ pid: Int32) throws -> (idle: Bool?, output: String) {
        let command = try #require(HostCommands.shellStateCommand(pid: pid))
        let result = try run(["/bin/sh", "-c", command], environment: ["PATH": "/usr/bin:/bin"], in: URL(fileURLWithPath: "/"))
        return (HostCommands.shellIsIdle(status: result.status, output: result.output), result.output)
    }

    @Test
    func the_shell_state_check_tells_a_prompt_from_a_command() async throws {
        // An interactive shell on a pty of its own, as a plain shell on a
        // host. `ps` of this Mac runs the same text as a host does.
        // script(1) makes the pty the shell's controlling terminal, as sshd
        // does; `PTYProcess` alone does not.
        let shell = try PTYProcess(
            ["/usr/bin/script", "-q", "/dev/null", "/bin/zsh", "-f", "-i"],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb"]
        )
        defer { shell.terminate() }
        // zsh drops input that comes before its first prompt (its line
        // editor turns on bracketed paste there).
        #expect(await shell.wait(for: "\u{1B}[?2004h"))
        // The prompt is `READY` and `%`: the echo of the line has a quote between them.
        shell.type("PS1=READY%#' '; echo PID=$$.\n")
        #expect(await shell.wait(for: "READY% "), "\(shell.output)")
        let pidText = try #require(shell.output.components(separatedBy: "PID=").last?.split(separator: ".").first)
        let pid = try #require(Int32(pidText))
        defer { kill(pid, SIGKILL) }
        let idle = try Self.shellState(pid)
        #expect(idle.idle == true, "\(idle.output)")
        shell.type("sleep 30\n")
        try await Task.sleep(for: .milliseconds(500))
        let busy = try Self.shellState(pid)
        #expect(busy.idle == false, "\(busy.output)")
    }

    @Test
    func the_shell_state_check_refuses_what_is_not_a_shell() throws {
        // This test process is no shell of /etc/shells.
        #expect(try Self.shellState(getpid()).idle == false)
        #expect(try Self.shellState(Int32.max).idle == nil)
    }

    @Test
    func the_shell_state_answer_is_read_only_when_it_is_clear() {
        #expect(HostCommands.shellIsIdle(status: 0, output: "Ss+\n0\nshell\n") == true)
        #expect(HostCommands.shellIsIdle(status: 0, output: "  I+  \n 0\nshell\n") == true)
        // A command runs: no `+`, a child in front, or a loop of its own.
        #expect(HostCommands.shellIsIdle(status: 0, output: "Ss\n0\nshell\n") == false)
        #expect(HostCommands.shellIsIdle(status: 0, output: "Ss+\n1\nshell\n") == false)
        #expect(HostCommands.shellIsIdle(status: 0, output: "R+\n0\nshell\n") == false)
        // The login shell ran `exec vim`.
        #expect(HostCommands.shellIsIdle(status: 0, output: "Ss+\n0\nother\n") == false)
        // No clear answer.
        #expect(HostCommands.shellIsIdle(status: 1, output: "Ss+\n0\nshell\n") == nil)
        #expect(HostCommands.shellIsIdle(status: 0, output: "") == nil)
        #expect(HostCommands.shellIsIdle(status: 0, output: "Ss+\n\nshell\n") == nil)
        #expect(HostCommands.shellIsIdle(status: 0, output: "ps: unknown option\n0\nshell\n") == nil)
        #expect(HostCommands.shellStateCommand(pid: 42)?.hasSuffix("' macterm 42") == true)
    }

    @Test
    func the_tilde_text_is_the_same_in_the_plain_script() throws {
        #expect(try scripts().plain.contains(HostCommands.expandTilde))
        #expect(try scripts().plain.contains(HostCommands.hexFolder))
    }

    // MARK: - The folder check of a new project (0358)

    @Test(arguments: ["/bin/sh", "/bin/csh"])
    func the_folder_check_finds_each_folder_under_a_login_shell(_ loginShell: String) throws {
        // With no server, sshd gives the command line to the login shell.
        let home = try Home()
        for (sent, _) in Self.folders {
            let command = try #require(HostCommands.folderCheckCommand(directory: sent))
            #expect(try Self.run([loginShell, "-c", command], environment: home.environment, in: home.url).status == 0, "\(sent)")
        }
        for sent in ["~/none", "/nonexistent;touch pwned", "~$(touch pwned)/x", "~a b/c"] {
            let command = try #require(HostCommands.folderCheckCommand(directory: sent))
            #expect(try Self.run([loginShell, "-c", command], environment: home.environment, in: home.url).status == 3, "\(sent)")
        }
        // A file is not a folder (0583).
        try home.makeFile("a b/notes.txt")
        let command = try #require(HostCommands.folderCheckCommand(directory: "~/a b/notes.txt"))
        #expect(try Self.run([loginShell, "-c", command], environment: home.environment, in: home.url).status == 4)
        #expect(home.nothingRan)
    }

    @Test
    func the_folder_check_runs_as_argv_with_a_server() throws {
        // With a server, `command.run` runs the argv with no login shell.
        let home = try Home()
        for (sent, _) in Self.folders {
            #expect(
                try Self.run(HostCommands.folderCheckArgv(directory: sent), environment: home.environment, in: home.url).status == 0,
                "\(sent)"
            )
        }
        for sent in ["~/none", "/nonexistent;touch pwned", "~$(touch pwned)/x"] {
            #expect(
                try Self.run(HostCommands.folderCheckArgv(directory: sent), environment: home.environment, in: home.url).status == 3,
                "\(sent)"
            )
        }
        // A file is not a folder (0583).
        try home.makeFile("it's/notes.txt")
        #expect(
            try Self.run(HostCommands.folderCheckArgv(directory: "~/it's/notes.txt"), environment: home.environment, in: home.url)
                .status == 4
        )
        #expect(home.nothingRan)
    }

    // MARK: - The folder list of a remote folder field (0614)

    @Test(arguments: ["/bin/sh", "/bin/csh"])
    func the_folder_list_names_the_folders_under_a_login_shell(_ loginShell: String) throws {
        let home = try Home()
        try home.makeFile("notes.txt")
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        let command = try #require(HostCommands.folderListCommand(directory: "~/"))
        let result = try Self.run([loginShell, "-c", command], environment: home.environment, in: home.url)
        let list = try #require(HostCommands.folderList(status: result.status, output: result.output))
        #expect(list.path == home.url.path, "the first line is the folder from /, with ~ resolved")
        let expected = HostCommandsTests.folders.compactMap(\.made) + [".hidden"]
        #expect(Set(list.names) == Set(expected), "folders only, hidden ones too: \(result.output)")
        // A folder with an odd name is listed from inside it too.
        for (sent, made) in Self.folders where made != nil {
            let inner = try #require(HostCommands.folderListCommand(directory: sent))
            let answer = try Self.run([loginShell, "-c", inner], environment: home.environment, in: home.url)
            #expect(HostCommands.folderList(status: answer.status, output: answer.output)?.path == home.expected(made), "\(sent)")
        }
        for sent in ["~/none", "/nonexistent;touch pwned", "~$(touch pwned)/x", "-n", "~/notes.txt"] {
            let missing = try #require(HostCommands.folderListCommand(directory: sent))
            #expect(try Self.run([loginShell, "-c", missing], environment: home.environment, in: home.url).status == 3, "\(sent)")
        }
        #expect(home.nothingRan)
    }

    @Test
    func the_process_folder_is_the_folder_of_the_process() throws {
        let home = try Home()
        let folder = home.url.appendingPathComponent("a b")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["5"]
        sleeper.currentDirectoryURL = folder
        try sleeper.run()
        defer { sleeper.terminate() }
        let argv = HostCommands.processFolderArgv(pid: sleeper.processIdentifier)
        let result = try Self.run(argv, environment: home.environment, in: home.url)
        let code = UInt8(truncatingIfNeeded: result.status)
        #expect(HostCommands.processFolder(code: code, output: result.output) == folder.path)
        // A pid with no process gives no folder.
        let none = try Self.run(HostCommands.processFolderArgv(pid: Int32.max), environment: home.environment, in: home.url)
        #expect(none.status != 0)
        #expect(HostCommands.processFolder(code: 0, output: "lsof: no such\n") == nil)
        #expect(HostCommands.processFolder(code: 1, output: "/srv\n") == nil)
        #expect(HostCommands.processFolder(code: nil, output: "/srv\n") == nil)
        #expect(HostCommands.processFolder(code: 0, output: "/srv/a\nb\n") == nil, "a folder with a newline in its name")
        #expect(HostCommands.processFolder(code: 0, output: "/srv/a\n") == "/srv/a")
    }

    @Test
    func the_folder_list_keeps_only_names_under_the_cap() {
        let names = (0 ..< HostCommands.folderListCap + 5).map { "f\($0)" }
        let output = "/srv\n" + names.joined(separator: "\n") + "\n"
        let list = HostCommands.folderList(status: 0, output: output)
        #expect(list?.path == "/srv")
        #expect(list?.names.count == HostCommands.folderListCap)
        #expect(HostCommands.folderList(status: 0, output: "/srv\n\na\n.\n..\nb/c\n")?.names == ["a"])
        #expect(HostCommands.folderList(status: 3, output: "/srv\na\n") == nil, "a folder that is not there")
        #expect(HostCommands.folderList(status: nil, output: "/srv\na\n") == nil, "no answer in time")
        #expect(HostCommands.folderList(status: 0, output: "motd text\n") == nil, "the first line must be a path")
    }

    @Test
    func only_the_scripts_own_answers_count() {
        #expect(RemoteHosts.folderCheck(status: 0) == .exists)
        #expect(RemoteHosts.folderCheck(status: 3) == .missing)
        #expect(RemoteHosts.folderCheck(status: 4) == .notDirectory)
        // A shell that failed to parse the script, a lost connection, a signal.
        for status: Int32? in [1, 2, 127, 255, nil] {
            #expect(RemoteHosts.folderCheck(status: status) == .unreachable)
        }
    }

    @Test
    func a_folder_that_the_host_reported_may_hold_a_quote_or_a_backslash() {
        #expect(HostCommands.isSafeHostFolder("/srv/app src"))
        #expect(HostCommands.isSafeHostFolder("~/dev"))
        #expect(!HostCommands.isSafeHostFolder("relative"))
        #expect(HostCommands.isSafeHostFolder("/srv\\x"))
        #expect(HostCommands.isSafeHostFolder("/srv/it's"))
        #expect(HostCommands.isSafeHostFolder("~/\"q\" $(x)"))
        #expect(HostCommands.isSafeHostFolder("/srv/semi;colon `x` ünï"))
        #expect(!HostCommands.isSafeHostFolder("/srv\tx"))
        #expect(!HostCommands.isSafeHostFolder("/srv\nrm -rf ~"))
    }

    @Test
    func a_plain_shell_is_a_login_shell_in_the_folder() throws {
        let command = try plain("~/dev/api")
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.hasSuffix("' macterm 7e2f6465762f617069"))
        #expect(command.contains("if [ -n \"$SHELL\" ]; then exec \"$SHELL\" -l; else exec /bin/sh; fi"))
        #expect(!command.contains("connect"))
        // Only the two quotes around the script, under any login shell.
        #expect(command.count { $0 == "'" } == 2)
    }

    @Test
    func pane_command_settles_term_against_the_hosts_own_terminfo() throws {
        // A resolvable TERM is never touched — the outer test is negated, so
        // the replacement only runs when the arriving TERM has no entry. That
        // precedence matters: preferring xterm-ghostty whenever the host had it
        // overrode a user's `SetEnv TERM=xterm-256color` pin and turned a stock
        // Debian prompt monochrome, since its ~/.bashrc gates color on
        // `xterm-color|*-256color` — a string match no capability check can
        // satisfy. Verified against a stubbed `infocmp` across all five cases.
        //
        // Decided host-side on purpose: `ghostty +ssh` forces
        // `-o SetEnv=TERM=xterm-ghostty` from the client because its wrapper has
        // no remote-side script; ours reads the remote DB directly, so it needs
        // no cache and works where env requests are dropped.
        for cmd in try [create(), plain("~")] {
            #expect(cmd.contains("if ! infocmp \"$TERM\" >/dev/null 2>&1; then "))
            #expect(cmd.contains("if infocmp xterm-ghostty >/dev/null 2>&1; then TERM=xterm-ghostty;"))
            #expect(cmd.contains("else TERM=xterm-256color; fi; export TERM; fi;"))
        }
        // Nested `if`, never `&&`/`||` chaining — the chained form's
        // left-to-right precedence binds the else-branch wrong.
        #expect(!HostCommands.remoteTermPreamble.contains("||"))
        // Pane-only: a background read has no terminal to describe.
        let probe = HostCommands.gitProbeScript
        #expect(!probe.contains("infocmp"))
    }

    @Test
    func pane_command_declares_truecolor_host_side() throws {
        // A remote pane's surface is libghostty, so 24-bit color is a fact,
        // but nothing carries it across ssh on its own: TERM rides the pty
        // request while everything else is an env request the server filters
        // (a Tailscale SSH host dropped SendEnv AND SetEnv COLORTERM even with
        // AcceptEnv COLORTERM effective). So the script asserts it itself.
        // Without this, helix refuses a truecolor theme ("theme requires true
        // color support") on any host where TERM isn't xterm-ghostty — which
        // `remoteTermPreamble` can't fix, since it only ever downgrades.
        #expect(create().contains("COLORTERM=truecolor; export COLORTERM;"))
        #expect(try plain("~").contains("COLORTERM=truecolor; export COLORTERM;"))
        // Pane-only: a background read renders nothing.
        let probe = HostCommands.gitProbeScript
        #expect(!probe.contains("COLORTERM"))
    }

    @Test
    func pane_command_declares_the_terminal_program_host_side() throws {
        // Claude Code sends OSC 9;4 progress — the agent's busy/done dot —
        // only to TERM_PROGRAM=ghostty at 1.2.0 or later, and ssh carries
        // neither variable on its own.
        #expect(create().contains(HostCommands.remoteTerminalProgramPreamble))
        #expect(try plain("~").contains(HostCommands.remoteTerminalProgramPreamble))
        #expect(HostCommands.remoteTerminalProgramPreamble.hasPrefix("TERM_PROGRAM=ghostty; export TERM_PROGRAM; "))
        let preamble = HostCommands.terminalProgramPreamble(version: "1.3.2-main+b368389")
        #expect(preamble.contains("TERM_PROGRAM_VERSION=1.3.2-main+b368389; export TERM_PROGRAM_VERSION;"))
        let probe = HostCommands.gitProbeScript
        #expect(!probe.contains("TERM_PROGRAM"))
    }

    @Test
    func terminal_program_preamble_drops_a_version_that_is_not_plain() {
        for version in [nil, "", "1.3; rm -rf ~", "1.3 beta", "1.3\"", "$(id)"] {
            let preamble = HostCommands.terminalProgramPreamble(version: version)
            #expect(preamble == "TERM_PROGRAM=ghostty; export TERM_PROGRAM; ")
        }
    }

    @Test
    func remote_scripts_never_source_profiles() throws {
        // Locked-in decision (#104): profiles are arbitrary code in the
        // pane's critical path. Sourcing them — inline, in a subshell, or
        // with stdin detached — produced three distinct pane-killers on real
        // hosts (exec hijack of our fds, tty-stdin read-block, profile
        // exec-loop spin). PATH comes from the fallback dir list.
        let probe = HostCommands.gitProbeScript
        for wire in try [create(), plain("~"), probe, HostCommands.folderCheckScript, HostCommands.hexFolder] {
            #expect(!wire.contains(".profile"))
            #expect(!wire.contains("/etc/profile"))
        }
    }

    // MARK: - Destination

    @Test
    func destination_composes_user_and_host() {
        #expect(HostCommands.destination(user: nil, host: "devbox") == "devbox")
        #expect(HostCommands.destination(user: "me", host: "devbox") == "me@devbox")
    }

    // MARK: - Git probe

    @Test
    func git_probe_runs_the_six_reads_in_one_command() {
        let script = HostCommands.gitProbeScript
        #expect(script.hasPrefix(HostCommands.remoteEnvPreamble))
        #expect(script.contains("d=$1; " + HostCommands.expandTilde + " cd \"$d\" 2>/dev/null || exit 2"))
        #expect(script.contains("command -v git >/dev/null 2>&1 || exit 3"))
        #expect(script.contains("status --porcelain=v2 --branch --show-stash 2>/dev/null) || exit 4"))
        #expect(script.contains("log -5 --format=%h%x1f%s%x1f%ct"))
        #expect(script.contains("for-each-ref refs/heads --sort=-committerdate --count=6"))
        #expect(script.contains("worktree list --porcelain"))
        #expect(script.contains("GIT_OPTIONAL_LOCKS=0"))
        #expect(script.contains("{ " + ProjectGit.branchLogScript(git: "git -c core.fsmonitor=false -c core.quotePath=false --no-pager")))
        // A detached HEAD has no branch log, and that is not a failure.
        #expect(script.contains("; } 2>/dev/null; printf"))
        // The diff only when a tracked file changed, as locally.
        #expect(script.hasSuffix(
            "if printf \"%s\\n\" \"$s\" | grep -q \"^[12u] \"; then "
                + ProjectGit.diffCommand(git: "git -c core.fsmonitor=false -c core.quotePath=false --no-pager") + "; fi; exit 0"
        ))
        #expect(script.components(separatedBy: "printf \"\\036\"").count == 6)
        // A git on the host's PATH only; profiles are never sourced.
        #expect(!script.contains("profile"))
    }
}
