@testable import Macterm
import Testing

/// The update button's state machine, driven by stand-in Sparkle callbacks.
struct UpdateStatusTests {
    private func found(
        _ stage: UpdateFound.Stage,
        userInitiated: Bool = true,
        informationOnly: Bool = false,
        untrusted: Bool = false
    ) -> UpdateEvent {
        .found(UpdateFound(
            stage: stage,
            userInitiated: userInitiated,
            informationOnly: informationOnly,
            untrusted: untrusted,
            version: "2.1.0"
        ))
    }

    @Test
    func idle_shows_no_button() {
        let machine = UpdateMachine()
        #expect(machine.status == .idle)
    }

    @Test
    func a_found_update_downloads_with_a_ring_then_offers_the_install_button() {
        var machine = UpdateMachine()
        machine.handle(.userCheckStarted)
        #expect(machine.handle(found(.notDownloaded)) == .init(reply: .install))
        #expect(machine.status == .idle)

        machine.handle(.downloadStarted)
        #expect(machine.status == .downloading(received: 0, expected: nil))
        #expect(machine.status.fraction == nil)

        machine.handle(.expectedLength(200))
        machine.handle(.receivedData(50))
        #expect(machine.status.fraction == 0.25)
        machine.handle(.receivedData(150))
        #expect(machine.status.fraction == 1)

        machine.handle(.extractionStarted)
        #expect(machine.status == .extracting)
        #expect(machine.status.fraction == nil)

        machine.handle(.readyToInstall(onQuit: false, version: nil))
        #expect(machine.status == .readyToRestart(version: "2.1.0"))
        #expect(machine.status.installTitle == "Update to v2.1.0")
    }

    /// A machine in a check that the user started.
    private func userCheck() -> UpdateMachine {
        var machine = UpdateMachine()
        machine.handle(.userCheckStarted)
        return machine
    }

    @Test
    func a_wrong_content_length_never_overfills_the_ring() {
        var machine = userCheck()
        machine.handle(.downloadStarted)
        machine.handle(.expectedLength(100))
        machine.handle(.receivedData(300))
        #expect(machine.status.fraction == 1)
    }

    @Test
    func a_zero_content_length_is_an_indeterminate_ring() {
        var machine = userCheck()
        machine.handle(.downloadStarted)
        machine.handle(.expectedLength(0))
        machine.handle(.receivedData(10))
        #expect(machine.status.fraction == nil)
    }

    /// Sparkle downloads a scheduled update by itself. The toolbar shows
    /// nothing until the update is ready.
    @Test
    func a_scheduled_download_shows_only_the_install_button_when_ready() {
        var machine = UpdateMachine()
        machine.handle(.readyToInstall(onQuit: true, version: "2.2.0"))
        #expect(machine.status == .readyToRestart(version: "2.2.0"))
        #expect(machine.status.installTitle == "Update to v2.2.0")
    }

    /// A Tip build's version is the only name of that build, so it shows in
    /// full.
    @Test
    func a_tip_update_shows_its_whole_version() {
        let status = UpdateStatus.readyToRestart(version: "2.1.0-tip.57")
        #expect(status.installTitle == "Update to v2.1.0-tip.57")
    }

    /// A newer background download replaces the update that waits.
    @Test
    func a_newer_update_replaces_the_waiting_version() {
        var machine = UpdateMachine()
        machine.handle(.readyToInstall(onQuit: true, version: "2.2.0"))
        machine.handle(.readyToInstall(onQuit: true, version: "2.3.0"))
        #expect(machine.status == .readyToRestart(version: "2.3.0"))
    }

    /// With no version, the title does not guess one.
    @Test
    func an_update_with_no_version_keeps_the_plain_title() {
        #expect(UpdateStatus.readyToRestart(version: nil).installTitle == "Restart to Update")
        #expect(UpdateStatus.readyToRestart(version: "").installTitle == "Restart to Update")
    }

    /// A ready callback with no version after the session ended does not
    /// take the version of an earlier session.
    @Test
    func a_found_version_does_not_outlive_its_session() {
        var machine = UpdateMachine()
        machine.handle(found(.notDownloaded))
        machine.handle(.sessionEnded)
        machine.handle(.readyToInstall(onQuit: false, version: nil))
        #expect(machine.status == .readyToRestart(version: nil))
    }

    /// A scheduled check that goes through the user driver (an update that
    /// Sparkle cannot download by itself) is silent until it is ready.
    @Test
    func a_scheduled_check_through_the_driver_shows_no_ring_and_no_toast() {
        var machine = UpdateMachine()
        #expect(machine.handle(found(.notDownloaded, userInitiated: false)).reply == .install)
        machine.handle(.downloadStarted)
        machine.handle(.expectedLength(100))
        machine.handle(.receivedData(50))
        #expect(machine.status == .idle)
        machine.handle(.extractionStarted)
        #expect(machine.status == .idle)
        #expect(machine.handle(.failed).toast == nil)
        #expect(machine.status == .idle)

        var ready = UpdateMachine()
        ready.handle(found(.notDownloaded, userInitiated: false))
        ready.handle(.downloadStarted)
        ready.handle(.readyToInstall(onQuit: false, version: nil))
        #expect(ready.status == .readyToRestart(version: "2.1.0"))
    }

    @Test
    func a_check_that_finds_nothing_says_up_to_date() {
        var machine = userCheck()
        #expect(machine.handle(.notFound(upToDate: true)).toast == .upToDate)
        machine.handle(.sessionEnded)
        #expect(machine.status == .idle)
        #expect(!machine.userSession)
    }

    @Test
    func a_failed_check_and_a_failed_download_have_their_own_toast() {
        var check = userCheck()
        #expect(check.handle(.failed).toast == .checkFailed)
        #expect(check.status == .idle)

        var download = userCheck()
        download.handle(found(.notDownloaded))
        download.handle(.downloadStarted)
        download.handle(.receivedData(10))
        #expect(download.status == .downloading(received: 10, expected: nil))
        #expect(download.handle(.failed).toast == .downloadFailed)
        #expect(download.status == .idle)

        var extract = userCheck()
        extract.handle(.extractionStarted)
        #expect(extract.handle(.failed).toast == .downloadFailed)
    }

    @Test
    func a_check_with_no_update_for_another_reason_says_nothing() {
        var machine = UpdateMachine()
        machine.handle(.userCheckStarted)
        #expect(machine.handle(.notFound(upToDate: false)).toast == nil)
        #expect(machine.status == .idle)
    }

    @Test
    func an_error_after_the_drivers_ready_hides_the_button() {
        var machine = UpdateMachine()
        machine.handle(.downloadStarted)
        machine.handle(.extractionStarted)
        machine.handle(.readyToInstall(onQuit: false, version: nil))
        machine.handle(.failed)
        #expect(machine.status == .idle)
    }

    @Test
    func an_appcast_that_failed_its_signing_check_is_not_installed() {
        var machine = UpdateMachine()
        let shown = machine.handle(found(.notDownloaded, untrusted: true))
        #expect(shown == .init(reply: .dismiss, toast: .availableOnWebsite(version: "2.1.0")))
        var scheduled = UpdateMachine()
        #expect(scheduled.handle(found(.notDownloaded, userInitiated: false, untrusted: true)) == .init(reply: .dismiss))
    }

    @Test
    func a_waiting_update_survives_later_events() {
        var machine = UpdateMachine()
        machine.handle(.readyToInstall(onQuit: true, version: "2.2.0"))
        for event: UpdateEvent in [
            .sessionEnded,
            .failed,
            .notFound(upToDate: true),
            .downloadStarted,
            .extractionStarted,
        ] {
            machine.handle(event)
            #expect(machine.status == .readyToRestart(version: "2.2.0"), "after \(event)")
        }
    }

    @Test
    func a_check_finds_the_waiting_update_and_holds_it_for_restart() {
        var machine = UpdateMachine()
        let result = machine.handle(found(.installing))
        #expect(result.reply == .holdForRestart)
        #expect(machine.status == .readyToRestart(version: "2.1.0"))
    }

    @Test
    func restart_with_no_reply_in_hand_installs_when_the_check_finds_it() {
        var machine = UpdateMachine()
        machine.handle(.readyToInstall(onQuit: true, version: "2.1.0"))
        machine.handle(.restartRequested)
        #expect(machine.restartPending)
        #expect(machine.handle(found(.installing)).reply == .install)
        #expect(!machine.restartPending)
    }

    @Test
    func a_session_end_drops_a_pending_restart() {
        var machine = UpdateMachine()
        machine.handle(.restartRequested)
        machine.handle(.sessionEnded)
        #expect(machine.handle(found(.installing)).reply == .holdForRestart)
    }

    @Test
    func a_downloaded_update_resumes_with_install() {
        var machine = UpdateMachine()
        #expect(machine.handle(found(.downloaded, userInitiated: false)).reply == .install)
    }

    @Test
    func an_information_only_update_is_dismissed() {
        var machine = UpdateMachine()
        let shown = machine.handle(found(.notDownloaded, informationOnly: true))
        #expect(shown == .init(reply: .dismiss, toast: .availableOnWebsite(version: "2.1.0")))

        var scheduled = UpdateMachine()
        let quiet = scheduled.handle(found(.notDownloaded, userInitiated: false, informationOnly: true))
        #expect(quiet == .init(reply: .dismiss, toast: nil))
        #expect(scheduled.status == .idle)
    }

    @Test
    func toasts_are_one_plain_sentence() {
        #expect(UpdateToast.upToDate.title == "Macterm is up to date")
        #expect(UpdateToast.checkFailed.title == "Macterm cannot check for updates")
        #expect(UpdateToast.downloadFailed.title == "Macterm cannot download the update")
        #expect(UpdateToast.availableOnWebsite(version: "2.1.0").title == "Macterm 2.1.0 is available on the website")
    }
}
