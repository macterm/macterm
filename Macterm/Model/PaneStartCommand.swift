import Foundation

/// A command that a new pane runs when its shell starts. This is a
/// first-spawn input: only the first view of a pane gets it
/// (`SurfaceRegistry.makeView`), because a later view attaches a session that
/// is already past it, and `PaneSnapshot` does not persist it.
///
/// `launch(remote:cli:shell:)` is the one place that turns it into what the
/// surface starts. Both modes that type a line go through libghostty's
/// `initial_input`, which a pane on a session holds until the shell's first
/// prompt (`PaneSession.heldInput`).
struct PaneStartCommand: Equatable {
    enum Mode: Equatable {
        /// Typed into the shell verbatim, as if the user entered it at the
        /// prompt: a layout's `run:` (`FirstRunSeed`, `pinned.yaml`, project
        /// layout files), the CLI and App Intents. It can `cd` or `source`,
        /// and it goes into the shell's history. No shell-syntax handling:
        /// the working directory is set on the surface, not with a `cd`.
        case typed
        /// A palette `run:` action. It is never typed, so it never reaches
        /// the shell's history: it runs before the pane's shell, as the
        /// shell's parent, then gives way to it (`CustomPaletteLaunch`). The
        /// command goes in the pane's environment
        /// (`CustomPaletteScript.commandVariable`), so nothing in it is
        /// quoted into a shell's grammar, and the bundled CLI runs it
        /// (`CustomPaletteLaunch.wrapperArgv`). With no bundled CLI, the
        /// fixed line `CustomPaletteScript.trampoline` is typed instead and
        /// reads the command from the same variable. A remote pane is ssh,
        /// whose environment stays on this Mac, so there the command is typed
        /// for the host's shell.
        case wrapped
    }

    let text: String
    let mode: Mode

    static func typed(_ text: String) -> PaneStartCommand {
        PaneStartCommand(text: text, mode: .typed)
    }

    static func wrapped(_ text: String) -> PaneStartCommand {
        PaneStartCommand(text: text, mode: .wrapped)
    }

    /// What the surface starts for this command.
    struct Launch: Equatable {
        /// The line that libghostty types into the shell (`initial_input`),
        /// with its newline.
        var input: String?
        /// Put in front of the command that libghostty resolves.
        var wrapper: [String] = []
        /// Added to the pane's environment.
        var environment: [String: String] = [:]
    }

    /// The launch of `command` in a pane. `cli` is the bundled CLI's path,
    /// nil when there is none; `shell` runs a wrapped command.
    static func launch(_ command: PaneStartCommand?, remote: Bool, cli: String?, shell: String) -> Launch {
        guard let command, !command.text.isEmpty else { return Launch() }
        switch command.mode {
        case .typed,
             .wrapped where remote:
            return Launch(input: command.text + "\n")
        case .wrapped:
            let environment = [CustomPaletteScript.commandVariable: CustomPaletteScript.script(command.text)]
            guard let cli else {
                return Launch(input: CustomPaletteScript.trampoline + "\n", environment: environment)
            }
            return Launch(wrapper: CustomPaletteLaunch.wrapperArgv(cli: cli, shell: shell), environment: environment)
        }
    }
}
