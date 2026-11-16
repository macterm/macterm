import Foundation
@testable import Macterm
import Testing

struct HostCommandsTests {
    private let remote = ProjectPath.remote(user: nil, host: "devbox", directory: "~/dev/api")

    // MARK: - Pane command

    private let key = "0123abcd"

    private func attach(_ session: String = "macterm-api-abc123") -> String {
        HostCommands.createProbeScript(directory: "~/dev/api")
    }

    private func create(_ directory: String = "~/dev/api") -> String {
        HostCommands.createProbeScript(directory: directory)
    }

    @Test
    func a_hostile_folder_stays_text_in_the_host_command() throws {
        // A folder can come from the host (OSC 7). It must never run.
        let command = HostCommands.plainShellCommand(directory: "/nonexistent;echo INJECTED")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["SHELL": "/usr/bin/true", "TERM": "dumb", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.contains("cannot cd to /nonexistent;echo INJECTED"))
        #expect(!output.contains("\nINJECTED"))
    }

    @Test
    func a_folder_that_the_host_reported_must_be_a_plain_path() {
        #expect(HostCommands.isSafeHostFolder("/srv/app src"))
        #expect(HostCommands.isSafeHostFolder("~/dev"))
        #expect(!HostCommands.isSafeHostFolder("relative"))
        #expect(!HostCommands.isSafeHostFolder("/srv\\x"))
        #expect(!HostCommands.isSafeHostFolder("/srv/it's"))
        #expect(!HostCommands.isSafeHostFolder("/srv\nrm -rf ~"))
    }

    @Test
    func a_plain_shell_is_a_login_shell_in_the_folder() {
        let plain = HostCommands.plainShellCommand(directory: "~/dev/api")
        #expect(plain.hasPrefix("sh -c '"))
        #expect(plain.contains("cd ~/\"dev/api\""))
        #expect(plain.contains("if [ -n \"$SHELL\" ]; then exec \"$SHELL\" -l; else exec /bin/sh; fi"))
        #expect(!plain.contains("connect"))
        #expect(!plain.contains("ZMX_FOREGROUND_EVENTS"))
    }

    @Test
    func pane_command_settles_term_against_the_hosts_own_terminfo() {
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
        for cmd in [attach(), HostCommands.plainShellCommand(directory: "~")] {
            #expect(cmd.contains("if ! infocmp \"$TERM\" >/dev/null 2>&1; then "))
            #expect(cmd.contains("if infocmp xterm-ghostty >/dev/null 2>&1; then TERM=xterm-ghostty;"))
            #expect(cmd.contains("else TERM=xterm-256color; fi; export TERM; fi;"))
        }
        // Nested `if`, never `&&`/`||` chaining — the chained form's
        // left-to-right precedence binds the else-branch wrong.
        #expect(!HostCommands.remoteTermPreamble.contains("||"))
        // Pane-only: a background read has no terminal to describe.
        let probe = HostCommands.gitProbeScript(directory: "~/dev/api")
        #expect(!probe.contains("infocmp"))
    }

    @Test
    func pane_command_declares_truecolor_host_side() {
        // A remote pane's surface is libghostty, so 24-bit color is a fact,
        // but nothing carries it across ssh on its own: TERM rides the pty
        // request while everything else is an env request the server filters
        // (a Tailscale SSH host dropped SendEnv AND SetEnv COLORTERM even with
        // AcceptEnv COLORTERM effective). So the script asserts it itself.
        // Without this, helix refuses a truecolor theme ("theme requires true
        // color support") on any host where TERM isn't xterm-ghostty — which
        // `remoteTermPreamble` can't fix, since it only ever downgrades.
        #expect(attach().contains("COLORTERM=truecolor; export COLORTERM;"))
        #expect(HostCommands.plainShellCommand(directory: "~").contains("COLORTERM=truecolor; export COLORTERM;"))
        // Pane-only: a background read renders nothing.
        let probe = HostCommands.gitProbeScript(directory: "~/dev/api")
        #expect(!probe.contains("COLORTERM"))
    }

    @Test
    func pane_command_declares_the_terminal_program_host_side() {
        // Claude Code sends OSC 9;4 progress — the agent's busy/done dot —
        // only to TERM_PROGRAM=ghostty at 1.2.0 or later, and ssh carries
        // neither variable on its own.
        #expect(attach().contains(HostCommands.remoteTerminalProgramPreamble))
        #expect(HostCommands.remoteTerminalProgramPreamble.hasPrefix("TERM_PROGRAM=ghostty; export TERM_PROGRAM; "))
        let preamble = HostCommands.terminalProgramPreamble(version: "1.3.2-main+b368389")
        #expect(preamble.contains("TERM_PROGRAM_VERSION=1.3.2-main+b368389; export TERM_PROGRAM_VERSION;"))
        let probe = HostCommands.gitProbeScript(directory: "~/dev/api")
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
    func remote_scripts_never_source_profiles() {
        // Locked-in decision (#104): profiles are arbitrary code in the
        // pane's critical path. Sourcing them — inline, in a subshell, or
        // with stdin detached — produced three distinct pane-killers on real
        // hosts (exec hijack of our fds, tty-stdin read-block, profile
        // exec-loop spin). PATH comes from the fallback dir list.
        let probe = HostCommands.gitProbeScript(directory: "~/dev/api")
        for wire in [attach(), create(), HostCommands.plainShellCommand(directory: "~"), probe] {
            #expect(!wire.contains(".profile"))
            #expect(!wire.contains("/etc/profile"))
        }
    }

    @Test
    func pane_command_script_is_single_quote_free() {
        // Single quotes in the script would break the `sh -c '<script>'`
        // wrapper on a non-POSIX login shell: the only two wrap it.
        let cmd = HostCommands.plainShellCommand(directory: "/srv/app")
        #expect(cmd.count { $0 == "'" } == 2)
    }

    // MARK: - Quoting

    @Test
    func shell_quote_survives_spaces_dollars_and_quotes() {
        #expect(HostCommands.shellQuote("plain") == "'plain'")
        #expect(HostCommands.shellQuote("with space") == "'with space'")
        #expect(HostCommands.shellQuote("$HOME") == "'$HOME'")
        #expect(HostCommands.shellQuote("it's") == "'it'\\''s'")
    }

    @Test
    func remote_directory_keeps_tilde_expandable() {
        // A quoted tilde is a literal directory named "~" — the tilde segment
        // must stay bare so sh expands it. Double quotes, so the containing
        // sh -c script stays single-quote-free.
        #expect(HostCommands.quoteRemoteDirectory("~") == "~")
        #expect(HostCommands.quoteRemoteDirectory("~/dev/api") == "~/\"dev/api\"")
        #expect(HostCommands.quoteRemoteDirectory("~/dir with space") == "~/\"dir with space\"")
        #expect(HostCommands.quoteRemoteDirectory("~deploy/app") == "~deploy/\"app\"")
        #expect(HostCommands.quoteRemoteDirectory("~deploy") == "~deploy")
    }

    @Test
    func remote_directory_quotes_plain_paths_whole() {
        #expect(HostCommands.quoteRemoteDirectory("/srv/my app") == "\"/srv/my app\"")
        #expect(HostCommands.quoteRemoteDirectory("work/api") == "\"work/api\"")
    }

    // MARK: - Security: tilde-segment injection (§5.3)

    @Test
    func remote_directory_never_ships_a_command_substitution_unquoted() {
        // Only a literal `~` or a `[A-Za-z0-9._-]` username may stay bare. A
        // tilde segment carrying `$(...)`, backticks, or spaces is NOT expandable
        // config — it's an injection vector — so the WHOLE string is
        // double-quoted (escaping `$`/backtick), never emitted raw into the `cd`.
        #expect(HostCommands.quoteRemoteDirectory("~$(touch /tmp/pwned)/sub") == "\"~\\$(touch /tmp/pwned)/sub\"")
        // Slashless form must also be quoted (was previously returned verbatim).
        #expect(HostCommands.quoteRemoteDirectory("~$(id)") == "\"~\\$(id)\"")
        #expect(HostCommands.quoteRemoteDirectory("~`id`") == "\"~\\`id\\`\"")
        // A username with a space is not a valid bare-safe name → fully quoted.
        #expect(HostCommands.quoteRemoteDirectory("~evil user/app") == "\"~evil user/app\"")
    }

    @Test
    func remote_directory_bare_forms_produce_no_shell_metacharacters() {
        // Every bare (unquoted) result must be free of shell-active characters,
        // so nothing a tilde path can carry reaches `sh` unquoted.
        for input in ["~", "~/dev/api", "~deploy/app", "~$(cmd)/x", "~a b/c", "/abs/$x"] {
            let quoted = HostCommands.quoteRemoteDirectory(input)
            // Strip the double-quoted spans; whatever remains bare must be inert.
            let bareParts = quoted.split(separator: "\"", omittingEmptySubsequences: false)
                .enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element).joined()
            #expect(!bareParts.contains("$"), "bare `$` leaked for \(input): \(quoted)")
            #expect(!bareParts.contains("`"), "bare backtick leaked for \(input): \(quoted)")
            #expect(!bareParts.contains(" "), "bare space leaked for \(input): \(quoted)")
        }
    }

    // MARK: - Security: single-quote-free wire invariant (§5.4)

    @Test
    func assert_single_quote_free_passes_clean_scripts_through() {
        let clean = "PATH=$PATH; exec \"zmx\" attach \"macterm-x-abc\""
        #expect(HostCommands.assertSingleQuoteFree(clean) == clean)
    }

    @Test
    func assert_single_quote_free_replaces_a_script_carrying_a_single_quote() {
        // A `'` in a user-controlled field (the project dir) would, once
        // wrapped by `shellQuote`, become `'\''` — which fish/nu tokenize
        // differently than POSIX sh, the exact breakage the invariant prevents.
        // Such a script is swapped for a diagnostic that is itself quote-free.
        let dirty = "cd \"~/it's-a-dir\"; exec zmx"
        let result = HostCommands.assertSingleQuoteFree(dirty)
        #expect(result != dirty)
        #expect(!result.contains("'"))
        #expect(result.contains("unsupported single quote"))
        #expect(result.contains("exec ${SHELL:-/bin/sh}"))
    }

    @Test
    func posix_double_quote_escapes_shell_metacharacters() {
        #expect(HostCommands.posixDoubleQuote("plain") == "\"plain\"")
        #expect(HostCommands.posixDoubleQuote("a$b") == "\"a\\$b\"")
        #expect(HostCommands.posixDoubleQuote("a\"b") == "\"a\\\"b\"")
        #expect(HostCommands.posixDoubleQuote("a`b") == "\"a\\`b\"")
        #expect(HostCommands.posixDoubleQuote("a\\b") == "\"a\\\\b\"")
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
        let script = HostCommands.gitProbeScript(directory: "~/dev/api")
        #expect(script.hasPrefix(HostCommands.remoteEnvPreamble))
        #expect(script.contains("cd ~/\"dev/api\" 2>/dev/null || exit 2"))
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

    @Test
    func git_probe_reads_a_folder_with_a_single_quote() {
        // The script is one argument of `command.run`, not text that a login
        // shell parses, so a single quote inside double quotes is safe.
        #expect(HostCommands.gitProbeScript(directory: "/it's").contains("cd \"/it's\" 2>/dev/null || exit 2"))
    }
}
