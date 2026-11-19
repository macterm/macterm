import Foundation
@testable import Macterm
import Testing

/// The one start function of a command in a new pane: what each mode gives
/// the surface.
struct PaneStartCommandTests {
    private let cli = "/App/bin/macterm"

    @Test
    func a_typed_command_is_the_shells_input_and_nothing_else() {
        let launch = PaneStartCommand.launch(.typed("cd src && make"), remote: false, cli: cli, shell: "/bin/zsh")
        #expect(launch == PaneStartCommand.Launch(input: "cd src && make\n"))
    }

    @Test
    func a_typed_command_is_typed_in_a_remote_pane_too() {
        let launch = PaneStartCommand.launch(.typed("htop"), remote: true, cli: cli, shell: "/bin/zsh")
        #expect(launch == PaneStartCommand.Launch(input: "htop\n"))
    }

    @Test
    func a_wrapped_command_runs_from_the_environment_through_the_cli_and_is_never_typed() {
        let launch = PaneStartCommand.launch(.wrapped("\n  #!/usr/bin/env nu\nls"), remote: false, cli: cli, shell: "/opt/homebrew/bin/nu")
        #expect(launch.input == nil)
        #expect(launch.wrapper == CustomPaletteLaunch.wrapperArgv(cli: cli, shell: "/opt/homebrew/bin/nu"))
        #expect(launch.environment == [CustomPaletteScript.commandVariable: "#!/usr/bin/env nu\nls"])
    }

    @Test
    func a_wrapped_command_with_no_bundled_cli_types_the_fixed_line_that_reads_the_environment() {
        let launch = PaneStartCommand.launch(.wrapped("make test"), remote: false, cli: nil, shell: "/bin/zsh")
        #expect(launch.input == CustomPaletteScript.trampoline + "\n")
        #expect(launch.wrapper.isEmpty)
        #expect(launch.environment == [CustomPaletteScript.commandVariable: "make test"])
    }

    @Test
    func a_wrapped_command_in_a_remote_pane_is_typed_because_ssh_carries_no_environment() {
        let launch = PaneStartCommand.launch(.wrapped("htop"), remote: true, cli: cli, shell: "/bin/zsh")
        #expect(launch == PaneStartCommand.Launch(input: "htop\n"))
    }

    @Test
    func no_command_or_an_empty_one_starts_a_plain_shell() {
        #expect(PaneStartCommand.launch(nil, remote: false, cli: cli, shell: "/bin/zsh") == PaneStartCommand.Launch())
        #expect(PaneStartCommand.launch(.typed(""), remote: false, cli: cli, shell: "/bin/zsh") == PaneStartCommand.Launch())
        #expect(PaneStartCommand.launch(.wrapped(""), remote: false, cli: cli, shell: "/bin/zsh") == PaneStartCommand.Launch())
    }
}
