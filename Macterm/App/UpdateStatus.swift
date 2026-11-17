import Foundation

/// What the toolbar shows for an update. Macterm draws its own update UI
/// (`UpdateUserDriver`), so Sparkle shows no dialog.
///
/// `idle` shows no button: the button is for the exception only.
enum UpdateStatus: Equatable {
    case idle
    /// Bytes received, and the size when Sparkle knows it. A background
    /// download (`SPUUpdaterDelegate`) reports no bytes.
    case downloading(received: UInt64, expected: UInt64?)
    case extracting
    /// The update waits. It installs when the app quits, or at once when the
    /// user clicks Restart to Update.
    case readyToRestart

    /// The fraction for a determinate ring, or nil for an indeterminate one.
    var fraction: Double? {
        guard case let .downloading(received, expected?) = self, expected > 0 else { return nil }
        return min(Double(received) / Double(expected), 1)
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
    case notFound
    /// Sparkle reports an error to the user driver. The user knows that a
    /// check or download runs.
    case failed
    case downloadStarted
    case expectedLength(UInt64)
    case receivedData(UInt64)
    case extractionStarted
    case readyToInstall
    /// `SPUUpdaterDelegate`: a download that Sparkle does by itself, with no
    /// user driver.
    case backgroundDownloadStarted
    /// `SPUUpdaterDelegate`: a background download or check stopped.
    case backgroundFailed
    /// Sparkle ends the update session (`dismissUpdateInstallation`).
    case sessionEnded
    /// The user clicked Restart to Update.
    case restartRequested
}

/// The update that Sparkle found, with only the facts the choice needs.
struct UpdateFound: Equatable {
    enum Stage: Equatable { case notDownloaded, downloaded, installing }
    var stage: Stage
    var userInitiated: Bool
    var informationOnly: Bool
    var version: String
}

/// The reply to Sparkle's `showUpdateFound`.
enum UpdateFoundReply: Equatable {
    /// Download (or extract, or install) the update now.
    case install
    /// Keep the reply. Restart to Update sends `install` later.
    case holdForRestart
    /// Close the session. The update is information only: the app cannot
    /// install it.
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
/// `readyToRestart` is sticky: Sparkle installs a waiting update when the
/// app quits, whatever a later check or error says.
struct UpdateMachine: Equatable {
    private(set) var status: UpdateStatus = .idle
    /// The user clicked Restart to Update while Macterm had no reply to send.
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
            break
        case let .found(found):
            result = handleFound(found)
        case .notFound:
            result.toast = .upToDate
            settle()
        case .failed:
            result.toast = status.isBusy ? .downloadFailed : .checkFailed
            settle()
        case .downloadStarted:
            if status != .readyToRestart { status = .downloading(received: 0, expected: nil) }
        case let .expectedLength(length):
            if case let .downloading(received, _) = status {
                status = .downloading(received: received, expected: length)
            }
        case let .receivedData(length):
            if case let .downloading(received, expected) = status {
                status = .downloading(received: received + length, expected: expected)
            }
        case .extractionStarted:
            if status != .readyToRestart { status = .extracting }
        case .readyToInstall:
            status = .readyToRestart
        case .backgroundDownloadStarted:
            if status == .idle { status = .downloading(received: 0, expected: nil) }
        case .backgroundFailed:
            if status.isBusy { status = .idle }
        case .sessionEnded:
            settle()
        case .restartRequested:
            restartPending = true
        }
        return result
    }

    private mutating func handleFound(_ found: UpdateFound) -> Result {
        if found.informationOnly {
            return Result(
                reply: .dismiss,
                toast: found.userInitiated ? .availableOnWebsite(version: found.version) : nil
            )
        }
        switch found.stage {
        case .installing:
            // The update waits for the app to quit. A check that the user
            // started finds it again: show Restart to Update, and install at
            // once only if the user already clicked it.
            status = .readyToRestart
            if restartPending {
                restartPending = false
                return Result(reply: .install)
            }
            return Result(reply: .holdForRestart)
        case .notDownloaded,
             .downloaded:
            return Result(reply: .install)
        }
    }

    /// The session ended. A waiting update stays; anything else goes.
    private mutating func settle() {
        restartPending = false
        if status != .readyToRestart { status = .idle }
    }
}
