import Foundation

/// What the toolbar shows for an update. Macterm draws its own update UI
/// (`UpdateUserDriver`), so Sparkle shows no dialog.
///
/// `idle` shows no button: the button is for the exception only.
enum UpdateStatus: Equatable {
    case idle
    /// Bytes received, and the size when Sparkle knows it. Only for an
    /// update that a check of the user found: a scheduled download shows
    /// nothing until the update is ready.
    case downloading(received: UInt64, expected: UInt64?)
    case extracting
    /// The update waits. It installs when the app quits, or at once when the
    /// user clicks the button. `version` is Sparkle's display version of the
    /// update, or nil when no callback named it.
    case readyToRestart(version: String?)

    /// The fraction for a determinate ring, or nil for an indeterminate one.
    var fraction: Double? {
        guard case let .downloading(received, expected?) = self, expected > 0 else { return nil }
        return min(Double(received) / Double(expected), 1)
    }

    var isReadyToRestart: Bool {
        if case .readyToRestart = self { return true }
        return false
    }

    /// The title of the button that installs the waiting update: Update to
    /// v2.1.0. A Tip build shows its whole version (2.1.0-tip.57). That is
    /// the only name of the build. With no version, the title does not guess
    /// one.
    var installTitle: String {
        guard case let .readyToRestart(version?) = self, !version.isEmpty else {
            return String(localized: "Restart to Update")
        }
        return String(
            localized: "Update to v\(version)",
            comment: "Toolbar button that installs the downloaded update and relaunches. The value is a version number, for example 2.1.0."
        )
    }

    var isBusy: Bool {
        switch self {
        case .downloading,
             .extracting: true
        case .idle,
             .readyToRestart: false
        }
    }
}

/// The callbacks of Sparkle's user driver and updater delegate, as plain values.
enum UpdateEvent: Equatable {
    /// The user started a check (menu, Settings, palette).
    case userCheckStarted
    case found(UpdateFound)
    /// `upToDate` is false when Sparkle found no update for another reason
    /// (the newest build needs another macOS, an unknown reason). Macterm
    /// then says nothing, because "up to date" would be wrong.
    case notFound(upToDate: Bool)
    /// Sparkle reports an error to the user driver. The user knows that a
    /// check or download runs.
    case failed
    case downloadStarted
    case expectedLength(UInt64)
    case receivedData(UInt64)
    case extractionStarted
    /// The update waits to install. `onQuit` is true for a background
    /// download that Sparkle installs when the app quits
    /// (`willInstallUpdateOnQuit`). `version` is the update's display
    /// version when the callback names it. The user driver's ready callback
    /// does not, and the machine then uses the version of the found update.
    case readyToInstall(onQuit: Bool, version: String?)
    /// Sparkle ends the update session (`dismissUpdateInstallation`).
    case sessionEnded
    /// The user clicked the button that installs the waiting update.
    case restartRequested
}

/// The update that Sparkle found, with only the facts the choice needs.
struct UpdateFound: Equatable {
    enum Stage: Equatable { case notDownloaded, downloaded, installing }
    var stage: Stage
    var userInitiated: Bool
    var informationOnly: Bool
    /// The appcast failed its signing check. Macterm never installs it.
    /// A major upgrade is not special: Sparkle hands it to the user driver
    /// instead of downloading it by itself, and Macterm installs it as any
    /// other update.
    var untrusted: Bool
    var version: String
}

/// The reply to Sparkle's `showUpdateFound`.
enum UpdateFoundReply: Equatable {
    /// Download (or extract, or install) the update now.
    case install
    /// Keep the reply. The install button sends `install` later.
    case holdForRestart
    /// Close the session. Macterm cannot install the update (information
    /// only, or an appcast that failed its signing check).
    case dismiss
}

/// A one-sentence toast for the outcome of a check that the user can see.
enum UpdateToast: Equatable {
    case upToDate
    case checkFailed
    case downloadFailed
    case availableOnWebsite(version: String)

    var title: String {
        switch self {
        case .upToDate: String(localized: "Macterm is up to date")
        case .checkFailed: String(localized: "Macterm cannot check for updates")
        case .downloadFailed: String(localized: "Macterm cannot download the update")
        case let .availableOnWebsite(version): String(localized: "Macterm \(version) is available on the website")
        }
    }
}

/// The pure state machine from Sparkle's callbacks to the toolbar button.
/// `Updater` owns one and does what each result asks.
///
/// A scheduled check is silent until its update is ready: no ring and no
/// toast. Only a check that the user started shows Downloading… and toasts.
///
/// `readyToRestart` from a background download is sticky: Sparkle installs
/// it when the app quits, whatever a later check or error says.
struct UpdateMachine: Equatable {
    private(set) var status: UpdateStatus = .idle
    /// Sparkle installs the waiting update when the app quits.
    private(set) var installsOnQuit = false
    /// The session is a check that the user started. Only such a session
    /// shows the ring and toasts.
    private(set) var userSession = false
    /// The display version of the update that this session found. The user
    /// driver's ready callback does not name its update.
    private(set) var foundVersion: String?
    /// The user clicked the install button while Macterm had no reply to send.
    /// The next found update at the installing stage then installs at once.
    private(set) var restartPending = false

    struct Result: Equatable {
        var reply: UpdateFoundReply?
        var toast: UpdateToast?
    }

    @discardableResult
    mutating func handle(_ event: UpdateEvent) -> Result {
        var result = Result()
        switch event {
        case .userCheckStarted:
            userSession = true
        case let .found(found):
            if found.userInitiated { userSession = true }
            result = handleFound(found)
        case let .notFound(upToDate):
            result.toast = upToDate && userSession ? .upToDate : nil
            settle()
        case .failed:
            if userSession { result.toast = status.isBusy ? .downloadFailed : .checkFailed }
            // An error after the user driver's ready ends that install. A
            // background download that waits still installs on quit.
            if status.isReadyToRestart, !installsOnQuit { status = .idle }
            settle()
        case .downloadStarted:
            if userSession, !status.isReadyToRestart { status = .downloading(received: 0, expected: nil) }
        case let .expectedLength(length):
            if case let .downloading(received, _) = status {
                status = .downloading(received: received, expected: length)
            }
        case let .receivedData(length):
            if case let .downloading(received, expected) = status {
                status = .downloading(received: received + length, expected: expected)
            }
        case .extractionStarted:
            if userSession, !status.isReadyToRestart { status = .extracting }
        case let .readyToInstall(onQuit, version):
            if onQuit { installsOnQuit = true }
            status = .readyToRestart(version: version ?? foundVersion)
        case .sessionEnded:
            settle()
        case .restartRequested:
            restartPending = true
        }
        return result
    }

    private mutating func handleFound(_ found: UpdateFound) -> Result {
        if found.informationOnly || found.untrusted {
            return Result(
                reply: .dismiss,
                toast: found.userInitiated ? .availableOnWebsite(version: found.version) : nil
            )
        }
        switch found.stage {
        case .installing:
            // The update waits for the app to quit. A check that the user
            // started finds it again: show the install button, and install at
            // once only if the user already clicked it.
            foundVersion = found.version
            status = .readyToRestart(version: found.version)
            if restartPending {
                restartPending = false
                return Result(reply: .install)
            }
            return Result(reply: .holdForRestart)
        case .notDownloaded,
             .downloaded:
            foundVersion = found.version
            return Result(reply: .install)
        }
    }

    /// The session ended. A waiting update stays; anything else goes.
    private mutating func settle() {
        restartPending = false
        userSession = false
        foundVersion = nil
        if !status.isReadyToRestart { status = .idle }
    }
}
