import Foundation
@testable import Macterm
import Testing

struct ForegroundSampleTests {
    private func sample(
        name: String?,
        isIdleShell: Bool = false
    ) -> ForegroundSample {
        ForegroundSample(name: name, isIdleShell: isIdleShell, sampledAt: Date())
    }

    // MARK: - plainShellNeedsConfirmClose (a host with no server, 0494)

    @Test
    func a_remote_pane_with_no_report_takes_the_surfaces_reading() {
        // The cause of 0494: a plain ssh shell never gets a report, so its
        // close used libghostty's reading, which is busy with no OSC 133
        // prompt mark. `plainShellNeedsConfirmClose` is the host's answer.
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: nil, executionState: .idle, isRemote: true,
            confirmClose: .true, surfaceBusy: { true }
        ))
    }

    @Test
    func a_plain_shell_warns_unless_its_host_says_idle() {
        #expect(!ForegroundPolicy.plainShellNeedsConfirmClose(shellIdle: true, executionState: .idle))
        #expect(ForegroundPolicy.plainShellNeedsConfirmClose(shellIdle: false, executionState: .idle))
        // A run that the pane's own marks show wins over the host's answer.
        #expect(ForegroundPolicy.plainShellNeedsConfirmClose(shellIdle: true, executionState: .running))
    }

    // MARK: - needsConfirmClose (the full verdict)

    @Test
    func no_surface_is_never_busy() {
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: nil, executionState: .running, isRemote: true,
            confirmClose: .true, surfaceBusy: nil
        ))
    }

    @Test
    func local_panes_trust_the_surface_signal_regardless_of_sample() {
        // libghostty's own verdict is authoritative locally — the sample is
        // naming state, never a busy override.
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: sample(name: "zsh", isIdleShell: true),
            executionState: .idle, isRemote: false,
            confirmClose: .true, surfaceBusy: { true }
        ))
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: sample(name: "btop"),
            executionState: .idle, isRemote: false,
            confirmClose: .true, surfaceBusy: { false }
        ))
    }

    @Test
    func remote_running_execution_state_is_busy_before_any_sample() {
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: nil, executionState: .running, isRemote: true,
            confirmClose: .true, surfaceBusy: { false }
        ))
    }

    @Test
    func remote_idle_shell_sample_is_not_busy() {
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: sample(name: "bash", isIdleShell: true),
            executionState: .idle, isRemote: true,
            confirmClose: .true, surfaceBusy: { true }
        ))
    }

    @Test
    func remote_program_sample_is_busy() {
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: sample(name: "btop", isIdleShell: false),
            executionState: .idle, isRemote: true,
            confirmClose: .true, surfaceBusy: { false }
        ))
    }

    @Test
    func remote_without_any_sample_falls_back_to_the_surface() {
        // Never silently kill an unknown foreground: a host with no server
        // reports nothing, and the conservative ssh-is-busy surface reading
        // stands in.
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: nil, executionState: .idle, isRemote: true,
            confirmClose: .true, surfaceBusy: { true }
        ))
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: nil, executionState: .idle, isRemote: true,
            confirmClose: .true, surfaceBusy: { false }
        ))
    }

    @Test
    func remote_verdict_reads_the_sampled_shellness_not_the_name() {
        // Shell-ness is judged at sampling time by the origin. The policy
        // must not re-derive it from the name — that re-derivation is
        // exactly the local-/etc/shells-vs-remote-host bug: a remote-only
        // login shell isn't in the local database, and only the recorded
        // verdict can say it was idle.
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: sample(name: "exotic-shell", isIdleShell: true),
            executionState: .idle, isRemote: true,
            confirmClose: .true, surfaceBusy: { true }
        ))
    }

    // MARK: - confirm-close-surface (0609)

    /// The verdict for one pane under `confirmClose`. `surfaceBusy` is
    /// libghostty's reading, which applies the key itself:
    /// `false` → false, `always` → true, `true` → busy when not at a prompt.
    private func verdict(
        _ confirmClose: ConfirmCloseSurface,
        sample: ForegroundSample?,
        executionState: TerminalExecutionState = .idle,
        isRemote: Bool,
        surfaceBusy: Bool
    ) -> Bool {
        ForegroundPolicy.needsConfirmClose(
            sample: sample, executionState: executionState, isRemote: isRemote,
            confirmClose: confirmClose, surfaceBusy: { surfaceBusy }
        )
    }

    @Test
    func false_never_warns_for_a_local_or_a_remote_pane() {
        // A local busy pane: libghostty reads false for the key.
        #expect(!verdict(.false, sample: sample(name: "btop"), isRemote: false, surfaceBusy: false))
        // A remote pane with a busy report, mid-run: its own signals would
        // warn, but the key turns the warning off.
        #expect(!verdict(.false, sample: sample(name: "btop"), executionState: .running, isRemote: true, surfaceBusy: false))
        // A remote idle shell.
        #expect(!verdict(.false, sample: sample(name: "bash", isIdleShell: true), isRemote: true, surfaceBusy: false))
    }

    @Test
    func always_warns_for_an_idle_local_or_remote_pane() {
        #expect(verdict(.always, sample: sample(name: "zsh", isIdleShell: true), isRemote: false, surfaceBusy: true))
        // A remote idle shell would close with no warning under `true`.
        #expect(verdict(.always, sample: sample(name: "bash", isIdleShell: true), isRemote: true, surfaceBusy: true))
    }

    @Test
    func true_warns_only_for_a_busy_pane() {
        #expect(verdict(.true, sample: sample(name: "btop"), isRemote: false, surfaceBusy: true))
        #expect(!verdict(.true, sample: sample(name: "zsh", isIdleShell: true), isRemote: false, surfaceBusy: false))
        #expect(verdict(.true, sample: sample(name: "btop"), isRemote: true, surfaceBusy: false))
        #expect(!verdict(.true, sample: sample(name: "bash", isIdleShell: true), isRemote: true, surfaceBusy: true))
    }

    // MARK: - remoteNeedsConfirmClose (the nil-able split)

    @Test
    func remote_verdict_is_nil_only_before_any_sample() {
        #expect(ForegroundPolicy.remoteNeedsConfirmClose(
            sample: nil, executionState: .idle
        ) == nil)
        #expect(ForegroundPolicy.remoteNeedsConfirmClose(
            sample: sample(name: "bash", isIdleShell: true), executionState: .idle
        ) == false)
        #expect(ForegroundPolicy.remoteNeedsConfirmClose(
            sample: sample(name: "hx"), executionState: .idle
        ) == true)
        #expect(ForegroundPolicy.remoteNeedsConfirmClose(
            sample: nil, executionState: .running
        ) == true)
    }
}
