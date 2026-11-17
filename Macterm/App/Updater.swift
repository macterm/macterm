import Combine
import os
import Sparkle
import SwiftUI

enum UpdaterAvailability {
    static let placeholderPublicKey = "SPARKLE_ED_PUBLIC_KEY_PLACEHOLDER"

    static func shouldStart(isDebug: Bool, isBenchmark: Bool, publicKey: String?) -> Bool {
        guard !isDebug, !isBenchmark, let publicKey, !publicKey.isEmpty else { return false }
        return publicKey != placeholderPublicKey
    }
}

/// Updates are always automatic: Sparkle checks the appcast daily
/// (`SUScheduledCheckInterval`), downloads a found update in the background
/// and installs it when the app quits. The toolbar then offers
/// Restart to Update.
///
/// Sparkle keeps both values in the user's defaults (`SUEnableAutomaticChecks`,
/// `SUAutomaticallyUpdate`), and they win over `Info.plist`. A user who turned
/// off an old toggle ("Check for updates automatically", "Update
/// automatically") still has it off there. `Updater` therefore writes both
/// values when the updater starts and again each time Sparkle schedules a
/// check. Sparkle reads `automaticallyDownloadsUpdates` when that check runs.
enum UpdatePolicy {
    @MainActor
    static func enforce(on updater: SPUUpdater) {
        if !updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = true }
        if !updater.automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = true }
    }
}

/// The updater and its own user interface. Macterm drives Sparkle with its own
/// user driver (`UpdateUserDriver`), so Sparkle shows no dialog. The toolbar
/// shows the exception: Downloading… with a progress ring, then Restart to
/// Update. A check that the user started ends in a toast. Release notes are
/// not shown in the app: they are on the changelog of the website.
///
/// We ship Sparkle with an EdDSA public key baked into `Info.plist`; updates
/// are verified against that key regardless of macOS code-signing state, so
/// auto-update works even though the app is only ad-hoc signed. Sparkle
/// downloads updates via its own networking path, so installed updates do
/// not pick up the `com.apple.quarantine` attribute and launch cleanly
/// without `xattr -cr`.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored
    private let sparkle: SPUUpdater
    @ObservationIgnored
    private let updaterDelegate = UpdaterDelegate()
    @ObservationIgnored
    private let userDriver = UpdateUserDriver()

    /// Exposes `canCheckForUpdates` for menu/UI disabled state.
    var canCheckForUpdates = false

    /// The pure state machine from Sparkle's callbacks to the toolbar button.
    private(set) var machine = UpdateMachine()

    var status: UpdateStatus { machine.status }

    /// `true` while Sparkle downloads or holds an update.
    var updateAvailable: Bool { machine.status != .idle }

    /// `true` once an update waits to install. Sparkle installs it when the
    /// app quits; Restart to Update installs it at once. Never cleared: the
    /// update installs when the app quits, whatever a later check says.
    var updateReadyToInstall: Bool { machine.status == .readyToRestart }

    /// Shows a toast in the windows. `MactermApp` sets it. With no window
    /// open, the toast has nowhere to show, and the menu item is the
    /// fallback.
    @ObservationIgnored
    var presentToast: ((String) -> Void)?

    /// What Restart to Update sends: the reply that `UpdateUserDriver` holds,
    /// or the handler of a background download (`willInstallUpdateOnQuit`).
    @ObservationIgnored
    private var heldInstallReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored
    private var installOnQuitHandler: (() -> Void)?

    @ObservationIgnored
    private var cancellable: AnyCancellable?

    private init() {
        // Debug and local Release builds have no production EdDSA key, so
        // Sparkle would fail to check on launch. Only a distributed release
        // with a real embedded key starts the updater. A scripted run
        // (MACTERM_BENCHMARK=1) of a local Release build has the placeholder
        // key too.
        let isDebug: Bool = {
            #if DEBUG
            true
            #else
            false
            #endif
        }()
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let startUpdater = UpdaterAvailability.shouldStart(
            isDebug: isDebug,
            isBenchmark: BenchmarkControl.isEnabled,
            publicKey: publicKey
        )

        sparkle = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: updaterDelegate
        )
        cancellable = sparkle.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }

        // Wire the callbacks before the updater starts, so that no check can
        // fire before they exist.
        userDriver.onEvent = { [weak self] event in self?.handle(event) }
        userDriver.onFound = { [weak self] found, reply in self?.handleFound(found, reply: reply) }
        userDriver.onReadyToInstall = { [weak self] reply in
            self?.heldInstallReply = reply
            self?.handle(.readyToInstall)
        }
        updaterDelegate.onEvent = { [weak self] event in self?.handle(event) }
        updaterDelegate.onReadyToInstall = { [weak self] handler in
            self?.installOnQuitHandler = handler
            self?.handle(.readyToInstall)
        }
        updaterDelegate.onWillScheduleCheck = { [sparkle] in
            UpdatePolicy.enforce(on: sparkle)
        }

        if startUpdater {
            UpdatePolicy.enforce(on: sparkle)
            do {
                try sparkle.start()
            } catch {
                logger.error("Updater did not start: \(EnglishErrorText.describe(error), privacy: .public)")
            }
        }
    }

    var updater: SPUUpdater { sparkle }

    func checkForUpdates() {
        guard sparkle.canCheckForUpdates else { return }
        sparkle.checkForUpdates()
    }

    /// Install the waiting update and relaunch, with no further UI. Quit is a
    /// detach (sessions survive), so the relaunch reattaches every pane.
    ///
    /// With no handler in hand, a check finds the waiting update again
    /// (`SPUUserUpdateStage.installing`), and the machine installs it then.
    func installAndRelaunch() {
        if let reply = heldInstallReply {
            heldInstallReply = nil
            reply(.install)
        } else if let installOnQuitHandler {
            installOnQuitHandler()
        } else {
            handle(.restartRequested)
            checkForUpdates()
        }
    }

    private func handle(_ event: UpdateEvent) {
        let result = machine.handle(event)
        if event == .sessionEnded || event == .failed || event == .notFound {
            // Sparkle's session ended: a held reply is no longer valid.
            heldInstallReply = nil
        }
        if let toast = result.toast { presentToast?(toast.title) }
    }

    private func handleFound(_ found: UpdateFound, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let result = machine.handle(.found(found))
        switch result.reply {
        case .install: reply(.install)
        case .dismiss: reply(.dismiss)
        case .holdForRestart: heldInstallReply = reply
        case nil: reply(.dismiss)
        }
        if let toast = result.toast { presentToast?(toast.title) }
    }

    /// The appcast channel updates are drawn from. Sparkle asks the delegate for
    /// `allowedChannels` on each check, so a change here lands on the next check
    /// without restarting.
    var updateChannel: UpdateChannel {
        get { Preferences.shared.updateChannel }
        set { Preferences.shared.updateChannel = newValue }
    }
}

private let logger = Logger(subsystem: appBundleID, category: "Updater")

/// Sparkle's channel name for beta builds. Must match the `<sparkle:channel>`
/// value written by `scripts/publish-appcast.sh`; the two are a wire contract,
/// so `UpdaterChannelTests` pins the literal.
///
/// Derived from `UpdateChannel.beta` rather than restated, so the persisted
/// preference value and the wire value can't drift apart.
let betaUpdateChannel = UpdateChannel.beta.rawValue

/// Sparkle's channel name for continuous builds of `main`. Same wire contract as
/// `betaUpdateChannel`, written by `.github/workflows/release-tip.yml` via
/// `publish-appcast.sh`'s `CHANNEL`.
let tipUpdateChannel = UpdateChannel.tip.rawValue

/// Receives Sparkle's updater callbacks: the channels, the schedule, and a
/// download that Sparkle does in the background with no user driver.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onEvent: ((UpdateEvent) -> Void)?
    var onReadyToInstall: ((@escaping () -> Void) -> Void)?
    var onWillScheduleCheck: (() -> Void)?

    /// Gates the prerelease channels on the user's selection. Sparkle calls
    /// this on every check (scheduled and user-initiated alike), so the picker
    /// needs no restart. Returning an empty set means "default channel only" —
    /// items carrying any `<sparkle:channel>` stay invisible.
    ///
    /// `nonisolated` + a `MainActor.assumeIsolated` read: Sparkle declares this
    /// delegate method non-isolated and calls it on the main thread, while
    /// `Preferences.shared` is `@MainActor`. Asserting the isolation we're
    /// already on beats caching a copy that could go stale mid-session.
    nonisolated func allowedChannels(for _: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated {
            switch Preferences.shared.updateChannel {
            case .stable: []
            case .beta: [betaUpdateChannel]
            // Deliberately NOT beta as well: tip is strictly ahead of beta, and
            // admitting both would only offer a tip follower an older build.
            case .tip: [tipUpdateChannel]
            }
        }
    }

    /// Sparkle calls this on the main thread each time it schedules the next
    /// background check. `Updater` writes `UpdatePolicy` again here.
    func updater(_: SPUUpdater, willScheduleUpdateCheckAfterDelay _: TimeInterval) {
        onWillScheduleCheck?()
    }

    /// A scheduled check downloads with no user driver. The toolbar shows an
    /// indeterminate ring until the download is ready or fails.
    func updater(_: SPUUpdater, willDownloadUpdate _: SUAppcastItem, with _: NSMutableURLRequest) {
        onEvent?(.backgroundDownloadStarted)
    }

    func updater(_: SPUUpdater, willExtractUpdate _: SUAppcastItem) {
        onEvent?(.extractionStarted)
    }

    func updater(_: SPUUpdater, failedToDownloadUpdate _: SUAppcastItem, error _: Error) {
        onEvent?(.backgroundFailed)
    }

    func updater(_: SPUUpdater, didAbortWithError _: Error) {
        onEvent?(.backgroundFailed)
    }

    /// Called on the main thread when a background download is ready to
    /// install on quit. Returning `true` takes control of the install: Sparkle
    /// still installs on quit, but it stops its own update cycles, so it never
    /// asks after `SUScheduledImpatientCheckInterval`. The toolbar's Restart to
    /// Update is the reminder instead. Sparkle 2.3 and later accepts the
    /// handler again after a cancelled termination.
    func updater(
        _: SPUUpdater,
        willInstallUpdateOnQuit _: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        onReadyToInstall?(immediateInstallHandler)
        return true
    }
}

/// Macterm's own `SPUUserDriver`: it shows no window. Each callback becomes an
/// `UpdateEvent` for `UpdateMachine`, and `Updater` answers Sparkle.
/// Sparkle calls every method on the main thread.
private final class UpdateUserDriver: NSObject, SPUUserDriver {
    var onEvent: ((UpdateEvent) -> Void)?
    var onFound: ((UpdateFound, @escaping (SPUUserUpdateChoice) -> Void) -> Void)?
    var onReadyToInstall: ((@escaping (SPUUserUpdateChoice) -> Void) -> Void)?

    /// Updates are always automatic (`UpdatePolicy`), so the answer is fixed.
    func show(_: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation _: @escaping () -> Void) {
        onEvent?(.userCheckStarted)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let stage: UpdateFound.Stage = switch state.stage {
        case .downloaded: .downloaded
        case .installing: .installing
        default: .notDownloaded
        }
        let found = UpdateFound(
            stage: stage,
            userInitiated: state.userInitiated,
            informationOnly: appcastItem.isInformationOnlyUpdate,
            version: appcastItem.displayVersionString
        )
        onFound?(found, reply)
    }

    /// Release notes are not shown in the app.
    func showUpdateReleaseNotes(with _: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_: Error) {}

    func showUpdateNotFoundWithError(_: Error, acknowledgement: @escaping () -> Void) {
        onEvent?(.notFound)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        logger.error("Update failed: \(EnglishErrorText.describe(error), privacy: .public)")
        onEvent?(.failed)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation _: @escaping () -> Void) {
        onEvent?(.downloadStarted)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        onEvent?(.expectedLength(expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        onEvent?(.receivedData(length))
    }

    func showDownloadDidStartExtractingUpdate() {
        onEvent?(.extractionStarted)
    }

    func showExtractionReceivedProgress(_: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onReadyToInstall?(reply)
    }

    func showInstallingUpdate(withApplicationTerminated _: Bool, retryTerminatingApplication _: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        onEvent?(.sessionEnded)
    }
}

/// The app menu's update item. While an update waits, it is Restart to Update,
/// the fallback when no window, and so no toolbar, is open.
/// Otherwise it is Check for Updates…, disabled while a check runs.
struct CheckForUpdatesMenuItem: View {
    /// `@Observable` singleton read directly — Observation tracks the reads
    /// in `body`, no `@ObservedObject` needed.
    private var updater: Updater { .shared }

    var body: some View {
        if updater.updateReadyToInstall {
            Button("Restart to Update") {
                updater.installAndRelaunch()
            }
        } else {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}

/// The update button of the main window's toolbar. It shows only for the
/// exception: Downloading… with a progress ring (determinate when Sparkle
/// knows the size), then Restart to Update, which installs and relaunches.
/// No button while idle.
struct UpdateToolbarButton: View {
    private var updater: Updater { .shared }

    var body: some View {
        switch updater.status {
        case .idle:
            EmptyView()
        case .downloading,
             .extracting:
            HStack(spacing: 6) {
                if let fraction = updater.status.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text("Downloading…")
            }
            .progressViewStyle(.circular)
            .controlSize(.small)
            .fixedSize()
            .help(String(localized: "Macterm is downloading an update."))
        case .readyToRestart:
            Button {
                updater.installAndRelaunch()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Restart to Update")
                }
                .foregroundStyle(.tint)
            }
            .fixedSize()
            .help(String(localized: "Restart Macterm to install the update."))
        }
    }
}
