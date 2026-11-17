@testable import Macterm
import Testing

/// The update button's state machine, driven by stand-in Sparkle callbacks.
struct UpdateStatusTests {
    private func found(
        _ stage: UpdateFound.Stage,
        userInitiated: Bool = true,
        informationOnly: Bool = false,
        needsConsent: Bool = false
    ) -> UpdateEvent {
        .found(UpdateFound(
            stage: stage,
            userInitiated: userInitiated,
            informationOnly: informationOnly,
            needsConsent: needsConsent,
            version: "2.1.0"
        ))
    }

    @Test
    func idle_shows_no_button() {
        let machine = UpdateMachine()
        #expect(machine.status == .idle)
    }

    @Test
    func a_found_update_downloads_with_a_ring_then_offers_restart() {
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

        machine.handle(.readyToInstall(onQuit: false))
        #expect(machine.status == .readyToRestart)
    }

    @Test
    func a_wrong_content_length_never_overfills_the_ring() {
        var machine = UpdateMachine()
        machine.handle(.downloadStarted)
        machine.handle(.expectedLength(100))
        machine.handle(.receivedData(300))
        #expect(machine.status.fraction == 1)
    }

    @Test
    func a_zero_content_length_is_an_indeterminate_ring() {
        var machine = UpdateMachine()
        machine.handle(.downloadStarted)
        machine.handle(.expectedLength(0))
        machine.handle(.receivedData(10))
        #expect(machine.status.fraction == nil)
    }

    @Test
    func a_background_download_shows_an_indeterminate_ring() {
        var machine = UpdateMachine()
        machine.handle(.backgroundDownloadStarted)
        #expect(machine.status == .downloading(received: 0, expected: nil))
        machine.handle(.extractionStarted)
        #expect(machine.status == .extracting)
        machine.handle(.readyToInstall(onQuit: true))
        #expect(machine.status == .readyToRestart)
    }

    @Test
    func a_failed_background_download_hides_the_button_with_no_toast() {
        var machine = UpdateMachine()
        machine.handle(.backgroundDownloadStarted)
        #expect(machine.handle(.backgroundFailed).toast == nil)
        #expect(machine.status == .idle)
    }

    @Test
    func a_check_that_finds_nothing_says_up_to_date() {
        var machine = UpdateMachine()
        machine.handle(.userCheckStarted)
        #expect(machine.handle(.notFound(upToDate: true)).toast == .upToDate)
        machine.handle(.sessionEnded)
        #expect(machine.status == .idle)
    }

    @Test
    func a_failed_check_and_a_failed_download_have_their_own_toast() {
        var check = UpdateMachine()
        check.handle(.userCheckStarted)
        #expect(check.handle(.failed).toast == .checkFailed)
        #expect(check.status == .idle)

        var download = UpdateMachine()
        download.handle(.downloadStarted)
        download.handle(.receivedData(10))
        #expect(download.handle(.failed).toast == .downloadFailed)
        #expect(download.status == .idle)

        var extract = UpdateMachine()
        extract.handle(.extractionStarted)
        #expect(extract.handle(.failed).toast == .downloadFailed)
    }

    /// Sparkle's order for a download that fails: the delegate's
    /// `failedToDownloadUpdate`, then the user driver's error.
    @Test
    func a_download_failure_in_sparkles_order_says_the_download_failed() {
        var machine = UpdateMachine()
        machine.handle(.userCheckStarted)
        machine.handle(found(.notDownloaded))
        machine.handle(.downloadStarted)
        machine.handle(.backgroundDownloadStarted)
        machine.handle(.receivedData(10))
        machine.handle(.backgroundFailed)
        #expect(machine.status == .downloading(received: 10, expected: nil))
        #expect(machine.handle(.failed).toast == .downloadFailed)
        machine.handle(.sessionEnded)
        #expect(machine.status == .idle)
        #expect(!machine.driverSession)
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
        machine.handle(.readyToInstall(onQuit: false))
        machine.handle(.failed)
        #expect(machine.status == .idle)
    }

    @Test
    func a_major_upgrade_is_not_installed() {
        var machine = UpdateMachine()
        let shown = machine.handle(found(.notDownloaded, needsConsent: true))
        #expect(shown == .init(reply: .dismiss, toast: .availableOnWebsite(version: "2.1.0")))
        var scheduled = UpdateMachine()
        #expect(scheduled.handle(found(.notDownloaded, userInitiated: false, needsConsent: true)) == .init(reply: .dismiss))
    }

    @Test
    func a_waiting_update_survives_later_events() {
        var machine = UpdateMachine()
        machine.handle(.readyToInstall(onQuit: true))
        for event: UpdateEvent in [
            .sessionEnded,
            .failed,
            .notFound(upToDate: true),
            .backgroundFailed,
            .downloadStarted,
            .extractionStarted,
            .backgroundDownloadStarted,
        ] {
            machine.handle(event)
            #expect(machine.status == .readyToRestart, "after \(event)")
        }
    }

    @Test
    func a_check_finds_the_waiting_update_and_holds_it_for_restart() {
        var machine = UpdateMachine()
        let result = machine.handle(found(.installing))
        #expect(result.reply == .holdForRestart)
        #expect(machine.status == .readyToRestart)
    }

    @Test
    func restart_with_no_reply_in_hand_installs_when_the_check_finds_it() {
        var machine = UpdateMachine()
        machine.handle(.readyToInstall(onQuit: true))
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
