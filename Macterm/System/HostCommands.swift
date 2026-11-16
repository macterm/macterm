import Foundation

/// Builds the commands that run on a remote host (#104). Every script is a
/// constant, and the data (a folder, a build key) goes to it as arguments,
/// never as shell text.
///
/// - **The host scripts** (`Scripts`, `server/host/`): the check, the
///   attach and the install of the host's server, and the plain shell for a
///   host with no server, sent as `sh -c '<script>' macterm <arguments>`
///   (`command`). sshd gives that line to the user's login shell, so each
///   argument is one plain word: the plain shell gets its folder hex-encoded.
///   The plain shell runs on the tty of an ssh channel over the host's one
///   connection (`SSHConnections.ttyArguments`, 0057). The login happened
///   before, in the master, so the channel never asks. It has no persistence.
/// - **A `command.run` script** (`createProbeScript`, `gitProbeScript`): the
///   host's server runs it as argv `/bin/sh -c <script> sh <folder>`
///   (`RemoteHosts.run`, 0058), so no login shell parses it. It opens no
///   connection of its own.
///
/// Port, identity, ControlMaster, and IPv6 literals are deliberately not
/// expressible here — point the host field at an `~/.ssh/config` alias for
/// those (the same stance the `path:` grammar took in #137).
enum HostCommands {
    /// The ssh destination for a parsed remote: `user@host` or bare `host`.
    static func destination(user: String?, host: String) -> String {
        if let user, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }

    /// PATH setup prepended to each script: append the common install dirs.
    /// sshd runs commands non-login/non-interactive with a bare PATH, so a
    /// zmx findable in an interactive session is otherwise invisible over
    /// `ssh host <cmd>`.
    ///
    /// Profiles (`/etc/profile`, `~/.profile`) are DELIBERATELY NOT sourced,
    /// in any form. They are arbitrary code in the pane's critical path, and
    /// every containment attempt leaked a new pane-killing failure mode,
    /// each found on a real or harness host:
    /// - inline + silenced: a `~/.profile` ending in `exec zsh` replaced the
    ///   script wholesale; the exec'd shell inherited stdout→/dev/null
    ///   (prompt visible via ZLE's /dev/tty, keystrokes via kernel pty echo,
    ///   output invisible, zmx never attached);
    /// - subshell harvest: the exec'd shell inherited the pane's tty stdin
    ///   and sat reading keystrokes forever, blocking before attach;
    /// - subshell + stdin</dev/null: a profile exec'ing a login shell that
    ///   re-reads the same profile spins in an exec loop no fd isolation
    ///   can unblock.
    /// The fallback dir list below covers where tools live in practice
    /// (`~/bin` included).
    static let remoteEnvPreamble =
        "PATH=\"$PATH:$HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin\"; "
            + "export PATH; "

    /// Prepended to the pane script only: settle TERM against the terminfo DB
    /// the remote actually has.
    ///
    /// **A TERM the host can already resolve is never touched** — including a
    /// coarser one the user pinned themselves (`SetEnv TERM=xterm-256color` in
    /// `~/.ssh/config`). Only an unusable arriving TERM is replaced, preferring
    /// `xterm-ghostty` when the host has that entry and falling back to the
    /// universally-known `xterm-256color`, because a TERM with no entry makes
    /// TUIs refuse to start.
    ///
    /// That precedence is load-bearing, and getting it backwards is a regression
    /// that looks like the opposite of one. An earlier revision *preferred*
    /// `xterm-ghostty` whenever the host had it, overriding the pin — and on a
    /// stock Debian host the prompt went monochrome, because the default
    /// `~/.bashrc` gates color on a string match:
    ///
    ///     case "$TERM" in xterm-color|*-256color) color_prompt=yes;; esac
    ///
    /// `xterm-ghostty` matches neither pattern, so a *more* capable terminal
    /// (that entry adds `Tc`; both report 256 colors) rendered a *plainer*
    /// prompt. Capability and dotfile heuristics are different things, and a
    /// pinned TERM is a decision the user already made about both — so we
    /// improve only what was broken anyway. `RemoteTerminfo` still unlocks full
    /// capabilities the honest way: with the entry installed, the TERM ssh
    /// forwards naturally *is* resolvable, so this keeps it instead of
    /// downgrading.
    ///
    /// Decided HOST-side, the deliberate divergence from `ghostty +ssh` — it
    /// forces `-o SetEnv=TERM=xterm-ghostty` from the client because its wrapper
    /// has no remote-side script to work with. Ours does, so it reads the remote
    /// DB directly: no guess about what the host has, no cache to fall out of
    /// sync with reality, and it works where env requests are dropped (see
    /// `remoteColorPreamble` on Tailscale SSH).
    ///
    /// POSIX nested `if`, not `&&`/`||` chaining — the chained form's
    /// left-to-right precedence makes the else-branch bind wrong.
    ///
    /// History, so nobody re-litigates: forcing `xterm-ghostty` was once tried
    /// *unconditionally*, "fixing" panes that rendered a prompt but no output
    /// on a host that has the ghostty terminfo. That experiment was confounded
    /// — the blind arm also sourced a `~/.profile` ending in `exec zsh` (the
    /// actual culprit; see `remoteEnvPreamble`). Retested un-confounded on the
    /// same host: zmx under TERM=xterm-ghostty renders fine. So the value is
    /// safe; what is not safe is imposing it.
    static let remoteTermPreamble =
        "if ! infocmp \"$TERM\" >/dev/null 2>&1; then "
            + "if infocmp xterm-ghostty >/dev/null 2>&1; then TERM=xterm-ghostty; "
            + "else TERM=xterm-256color; fi; export TERM; fi; "

    /// Prepended to the pane script only: 24-bit color is a property of the
    /// surface, and ours is libghostty — always truecolor — so the remote can
    /// be told unconditionally.
    ///
    /// It has to be asserted host-side because ssh carries only `TERM` by a
    /// channel a server can't refuse: TERM rides the *pty request* (and
    /// OpenSSH ≥8.7 lets `SetEnv` override the value put there), while every
    /// other variable is an `env` channel request the *server* filters. So the
    /// same `SetEnv` flag succeeds or vanishes depending only on which
    /// variable it names — measured against a real host behind Tailscale SSH
    /// (`tailscaled` serves the session, so the host's `AcceptEnv COLORTERM`
    /// is never consulted): `-o SetEnv=TERM=xterm-ghostty` arrived, while
    /// `-o SetEnv=COLORTERM=truecolor`, `-o SendEnv=COLORTERM`, and a control
    /// `-o SetEnv=FOO=bar` all arrived empty. Setting it inside the script
    /// depends on nothing but our own preamble, which is the rule the rest of
    /// this file follows.
    ///
    /// Without it, TUIs that gate 24-bit color on COLORTERM downgrade to 256
    /// colors or refuse outright — helix rejects a truecolor theme with
    /// "Unsupported theme: theme requires true color support". Note the
    /// `remoteTermPreamble` above can't cover this: it only ever *downgrades*
    /// TERM, so a `SetEnv TERM=xterm-256color` in the user's `~/.ssh/config`
    /// (or any host without the ghostty terminfo entry) leaves no truecolor
    /// signal at all. Ghostty.app escapes this by a route we don't have — its
    /// shell-integration `ssh` wrapper hands the connection to `ghostty +ssh`,
    /// which installs the `xterm-ghostty` entry on the host and forces
    /// `-o SetEnv=TERM=xterm-ghostty` (whose terminfo declares `Tc`). A
    /// Macterm pane command IS the surface command, spawned with no shell in
    /// front of it, so no such wrapper can ever run.
    ///
    /// Only sessions created from here on pick it up: `zmx attach` hands its
    /// environment to the shell it CREATES, so a session that predates this
    /// keeps the old one until it is killed.
    static let remoteColorPreamble = "COLORTERM=truecolor; export COLORTERM; "

    /// Prepended to the pane script only, after `remoteColorPreamble` and for
    /// the same reason: `TERM_PROGRAM`/`TERM_PROGRAM_VERSION` describe the
    /// surface, which libghostty sets for a local pane, and an `env` request
    /// carrying them (ghostty's own `ssh-env`, `SSHWrapper`'s `SendEnv`) is
    /// one the server may drop. Programs gate features on them: Claude Code
    /// emits OSC 9;4 progress — the sidebar's busy/done dot for an agent —
    /// only for `TERM_PROGRAM=ghostty` at version 1.2.0 or later, so a remote
    /// agent showed its logo and never its status.
    ///
    /// The version is libghostty's own (`GhosttyApp.version`), exactly what a
    /// local pane sees, and like the rest a process constant. Like COLORTERM,
    /// only sessions created from here on pick it up.
    static let remoteTerminalProgramPreamble = terminalProgramPreamble(version: GhosttyApp.version)

    /// Testable core of `remoteTerminalProgramPreamble`. The version is
    /// dropped unless it is all `[A-Za-z0-9.+_-]`, so nothing from it can
    /// reach the shell as syntax; `TERM_PROGRAM` is exported regardless.
    static func terminalProgramPreamble(version: String?) -> String {
        var preamble = "TERM_PROGRAM=ghostty; export TERM_PROGRAM; "
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+_-")
        if let version, !version.isEmpty, version.unicodeScalars.allSatisfy(allowed.contains) {
            preamble += "TERM_PROGRAM_VERSION=\(version); export TERM_PROGRAM_VERSION; "
        }
        return preamble
    }

    /// What a new remote session needs from the host, in one command that the
    /// host's server runs (`command.run`, `createProbeArgv`): the first line
    /// says if the folder is there (`ok`) or the pane falls back to the home
    /// folder (`home`), the second is the folder's physical path, and the rest
    /// is the environment after the same settling of `TERM`, `COLORTERM` and
    /// `TERM_PROGRAM` that a pane's script did. Never sources a profile.
    /// `session.create` has no shell to expand a `~`, so the host resolves it.
    /// The folder is `$1`, so no shell parses it. No ssh pty gave the server
    /// a TERM, and a shell may set a `dumb` one that it does not export: the
    /// first line replaces it, and exports the result.
    static let createProbeScript =
        "case \"$TERM\" in \"\"|dumb) TERM=xterm-256color; infocmp xterm-ghostty >/dev/null 2>&1 && TERM=xterm-ghostty;; esac; "
            + "export TERM; "
            + remoteTermPreamble + remoteColorPreamble + remoteTerminalProgramPreamble
            + "d=$1; " + expandTilde + " "
            + "if cd \"$d\" 2>/dev/null; then echo ok; else echo home; cd; fi; pwd -P; env"

    /// The `command.run` argv of `createProbeScript` for a folder.
    static func createProbeArgv(directory: String) -> [String] {
        ["/bin/sh", "-c", createProbeScript, "sh", directory]
    }

    /// Makes `$d` a folder that `cd` takes: a `~` or `~name` at the start
    /// becomes that home folder, as a shell expands it. A name with any
    /// character other than `[A-Za-z0-9._-]` stays as it is, because only a
    /// checked name goes into `eval`. The same text is in
    /// `server/host/plain.sh`.
    static let expandTilde = oneLine("""
    case $d in
      "~" | "~/"*) d=$HOME${d#"~"} ;;
      "~"*)
        n=${d%%/*};
        n=${n#"~"};
        if [ -z "$(printf "%s" "$n" | tr -d A-Za-z0-9._-)" ]; then
          eval "u=~$n";
          d=$u${d#"~$n"};
        fi;
        ;;
    esac;
    """)

    /// True for a folder that may go into a host command: a path (absolute,
    /// or from `~`) with no control character, no backslash and no single
    /// quote. A folder that the host reported (OSC 7) is the host's text: a
    /// backslash leaves `"…"` under fish, and a control character is never a
    /// folder the user typed.
    static func isSafeHostFolder(_ folder: String) -> Bool {
        guard folder.hasPrefix("/") || folder.hasPrefix("~") else { return false }
        return !folder.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || $0 == "\\" || $0 == "'"
        }
    }

    /// The git reads of the memory panel for a remote project, in one
    /// command that the host's server runs (`ProjectGit.remoteStatus`): the
    /// same six reads that `ProjectGit.status` runs locally, with their
    /// outputs separated by `ProjectGit.recordSeparator`. The diff runs only
    /// when the status has a changed tracked file (a line that starts with
    /// `1`, `2` or `u`), as locally. The script exits 2 when the directory
    /// is not there, 3 when the host has no git, 4 when the directory is not
    /// in a repository, and 0 in all other cases (`ProjectGit.branchLogScript`
    /// fails on a detached HEAD, which is not a failure of the read).
    /// `GIT_OPTIONAL_LOCKS=0` and `core.fsmonitor=false` for the same reasons
    /// as locally. Never sources a profile (see `remoteEnvPreamble`). The
    /// folder is `$1`, so no shell parses it.
    static let gitProbeScript: String = {
        let git = (["git"] + ProjectGit.gitOptions).joined(separator: " ")
        let separator = "printf \"\\036\""
        let branchFormat = "%(refname:short)%1f%(objectname:short)%1f%(committerdate:unix)%1f%(subject)"
        return remoteEnvPreamble
            + "GIT_OPTIONAL_LOCKS=0; GIT_TERMINAL_PROMPT=0; export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT; "
            + "d=$1; " + expandTilde + " "
            + "cd \"$d\" 2>/dev/null || exit 2; "
            + "command -v git >/dev/null 2>&1 || exit 3; "
            + "s=$(\(git) status --porcelain=v2 --branch --show-stash 2>/dev/null) || exit 4; "
            + "printf \"%s\\n\" \"$s\"; \(separator); "
            + "\(git) log -\(ProjectGit.recentCommitCount) --format=%h%x1f%s%x1f%ct 2>/dev/null; \(separator); "
            + "\(git) for-each-ref refs/heads --sort=-committerdate --count=\(ProjectGit.recentBranchCount) "
            + "--format=\"\(branchFormat)\" 2>/dev/null; \(separator); "
            + "\(git) worktree list --porcelain 2>/dev/null; \(separator); "
            + "{ \(ProjectGit.branchLogScript(git: git)); } 2>/dev/null; \(separator); "
            + "if printf \"%s\\n\" \"$s\" | grep -q \"^[12u] \"; then "
            + "\(ProjectGit.diffCommand(git: git)); fi; exit 0"
    }()

    /// The `command.run` argv of `gitProbeScript` for a folder.
    static func gitProbeArgv(directory: String) -> [String] {
        ["/bin/sh", "-c", gitProbeScript, "sh", directory]
    }

    /// The script with no comment lines and no empty lines, its lines joined
    /// with spaces. sshd gives the command to the user's login shell, and csh
    /// refuses a newline in single quotes. So each line of a host script is
    /// valid when it is joined to the next.
    static func oneLine(_ script: String) -> String {
        script.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: " ")
    }

    /// nil when the script has a single quote, a newline or a `!` that csh
    /// reads as history (one that a blank, `=` or `(` does not follow), or an argument
    /// is not one plain word (`isArgument`). Fail closed: nothing goes to the host then.
    static func command(_ script: String, _ arguments: [String]) -> String? {
        guard !script.contains("'"), !script.contains(where: \.isNewline), !hasHistoryMark(script),
              arguments.allSatisfy(isArgument)
        else { return nil }
        return "sh -c '\(script)' macterm " + arguments.joined(separator: " ")
    }

    static func hasHistoryMark(_ script: String) -> Bool {
        let characters = Array(script)
        return characters.indices.contains { index in
            characters[index] == "!" && index + 1 < characters.count
                && !(characters[index + 1].isWhitespace || "=(".contains(characters[index + 1]))
        }
    }

    /// Letters, digits and `-`, at most 64: a build key, a checksum, a host id.
    static func isWord(_ text: String) -> Bool {
        text.count <= 64 && isArgument(text)
    }

    /// Letters, digits and `-`, at most 8192: one plain word on a command
    /// line, also a folder in hex (`Scripts.plainCommand`).
    static func isArgument(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 8192 && text.unicodeScalars.allSatisfy {
            ("a" ... "z").contains($0) || ("A" ... "Z").contains($0) || ("0" ... "9").contains($0) || $0 == "-"
        }
    }
}

extension HostCommands {
    /// The scripts that run on a host (`server/host/`, in the bundle at
    /// `Contents/Resources/host`). The app sends each one as
    /// `sh -c '<script>' macterm <arguments>` (`HostCommands.command`), so a
    /// script has no single quote and each argument is one word.
    struct Scripts: Equatable {
        var attach: String
        var install: String
        var plain: String

        static var bundled: Scripts? {
            Bundle.main.resourceURL.flatMap { load(from: $0.appendingPathComponent("host", isDirectory: true)) }
        }

        /// Each script as the one line that goes to the host (`oneLine`).
        static func load(from directory: URL) -> Scripts? {
            guard let attach = try? String(contentsOf: directory.appendingPathComponent("attach.sh"), encoding: .utf8),
                  let install = try? String(contentsOf: directory.appendingPathComponent("install.sh"), encoding: .utf8),
                  let plain = try? String(contentsOf: directory.appendingPathComponent("plain.sh"), encoding: .utf8)
            else { return nil }
            return Scripts(
                attach: HostCommands.oneLine(attach),
                install: HostCommands.oneLine(install),
                plain: HostCommands.oneLine(plain)
            )
        }

        func attachCommand(key: String) -> String? {
            HostCommands.command(attach, [key])
        }

        func installCommand(key: String, sha256: String, hostID: String) -> String? {
            HostCommands.command(install, [key, sha256, hostID])
        }

        /// What a remote pane runs on a host with no server (the user
        /// declined the install, or the host has no build): a plain login
        /// shell in `directory`, as v1 without zmx, after the pane's TERM,
        /// COLORTERM and TERM_PROGRAM lines. The folder goes as hex, one
        /// plain word; no folder is the home folder. nil for a folder too
        /// long for one argument.
        func plainCommand(directory: String) -> String? {
            let hex = (directory.isEmpty ? "~" : directory).utf8.map { String(format: "%02x", $0) }.joined()
            let preambles = HostCommands.remoteTermPreamble + HostCommands.remoteColorPreamble
                + HostCommands.remoteTerminalProgramPreamble
            return HostCommands.command(preambles + plain, [hex])
        }
    }
}
