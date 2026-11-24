import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "SSHLoginPrompts")

/// The questions that the login of a host's ssh master asks, shown as sheets
/// (design/005 step 2): a secure field for a password or a passphrase, or
/// Connect and Cancel for a host key and a confirmation. One sheet at a time;
/// the next waits. The text is Macterm's for a question that it knows
/// (`Question`), and ssh's prompt line for any other.
///
/// A login that writes text and asks nothing (a host that waits for a log-in
/// in the browser) gets a notice sheet with ssh's last line and Cancel
/// (`LoginUI.showNotice`). It has Open Link when that line holds
/// an https link. The notice closes when the login ends.
///
/// A saved password for the login (filed under `ssh <destination>` and the
/// prompt line, as in v1) fills the answer only after a click on Use Saved
/// Password and the authentication of `PasswordAuthenticator`.
@MainActor
final class SSHLoginPrompts: LoginUI {
    static let shared = SSHLoginPrompts()

    typealias Request = SSHPrompt.Request
    typealias Kind = SSHPrompt.Kind
    typealias Answer = SSHPrompt.Answer
    typealias Asker = SSHPrompt.Asker
    typealias Question = SSHPrompt.Question

    private final class Pending {
        let request: Request
        let continuation: CheckedContinuation<Answer, Never>
        var sheet: (alert: NSAlert, window: NSWindow)?

        init(_ request: Request, _ continuation: CheckedContinuation<Answer, Never>) {
            self.request = request
            self.continuation = continuation
        }
    }

    private var queue: [Pending] = []
    private var current: Pending?
    /// The last secret prompt that each ssh got an answer to.
    private var answeredSecret: [Asker: String] = [:]

    func ask(_ request: Request) async -> Answer {
        await withCheckedContinuation { continuation in
            queue.append(Pending(request, continuation))
            presentNext()
        }
    }

    /// The master `pid` exited: its askpass is gone, so its questions are too.
    func cancel(sshPID pid: pid_t) {
        showNotice(host: "", sshPID: pid, line: nil)
        answeredSecret = answeredSecret.filter { $0.key.sshPID != pid }
        for pending in queue where pending.request.sshPID == pid {
            pending.continuation.resume(returning: .cancelled)
        }
        queue.removeAll { $0.request.sshPID == pid }
        guard let current, current.request.sshPID == pid else { return }
        if let sheet = current.sheet {
            sheet.window.endSheet(sheet.alert.window, returnCode: .abort)
        } else if NSApp.modalWindow != nil {
            NSApp.abortModal()
        }
    }

    // MARK: - Notice

    /// The notice of each login that waits, in the order they came. One
    /// sheet shows the first, when no question is open; the others wait.
    private var notices: [Notice] = []

    private struct Notice {
        var sshPID: pid_t
        var host: String
        var line: String
    }

    private var noticeSheet: NoticeSheet?
    /// Logins whose notice brought the app to the front once.
    private var activatedNotices: Set<pid_t> = []

    private struct NoticeSheet {
        var sshPID: pid_t
        var alert: NSAlert
        var window: NSWindow
        var line: String
        /// The Open Link button's target, kept while the sheet is up.
        var opener: LinkOpener?
    }

    /// Show `line` for the login of the master `pid`, or remove its notice
    /// when `line` is nil.
    func showNotice(host: String, sshPID pid: pid_t, line: String?) {
        if let line, !line.isEmpty {
            if let index = notices.firstIndex(where: { $0.sshPID == pid }) {
                notices[index].line = line
            } else {
                notices.append(Notice(sshPID: pid, host: host, line: line))
            }
        } else {
            notices.removeAll { $0.sshPID == pid }
            activatedNotices.remove(pid)
        }
        refreshNotice()
    }

    /// Show the first notice when no question is open, or close the sheet.
    private func refreshNotice() {
        let wanted = current == nil && queue.isEmpty ? notices.first : nil
        if let sheet = noticeSheet {
            if let wanted, wanted.sshPID == sheet.sshPID, (Self.link(in: wanted.line) == nil) == (sheet.opener == nil) {
                // The same login: change the text in place, so that a
                // line that changes does not open the sheet again.
                if wanted.line != sheet.line {
                    sheet.alert.informativeText = Self.noticeText(wanted.line)
                    if let url = Self.link(in: wanted.line) { sheet.opener?.url = url }
                    noticeSheet?.line = wanted.line
                }
                return
            }
            closeNoticeSheet()
        }
        // No terminal window: no notice. A modal alert would hold the wait
        // for the login that closes it.
        guard let wanted, let window = Self.sheetParent() else { return }
        let pid = wanted.sshPID
        let alert = NSAlert()
        alert.messageText = String(localized: "Connecting to \(wanted.host)")
        alert.informativeText = Self.noticeText(wanted.line)
        var opener: LinkOpener?
        if let url = Self.link(in: wanted.line) {
            let button = alert.addButton(withTitle: String(localized: "Open Link"))
            // Its own action: the sheet stays up until the login ends.
            let target = LinkOpener(url: url)
            button.target = target
            button.action = #selector(LinkOpener.open(_:))
            opener = target
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        noticeSheet = NoticeSheet(sshPID: pid, alert: alert, window: window, line: wanted.line, opener: opener)
        if activatedNotices.insert(pid).inserted { NSApp.activate() }
        let host = wanted.host
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, noticeSheet?.alert === alert else { return }
            noticeSheet = nil
            guard response != .abort else { return }
            logger.info("ssh notice for host=\(host, privacy: .public): cancelled")
            notices.removeAll { $0.sshPID == pid }
            SSHConnections.shared.cancelLogin(connectionPID: pid)
            refreshNotice()
        }
    }

    private func closeNoticeSheet() {
        guard let sheet = noticeSheet else { return }
        noticeSheet = nil
        sheet.window.endSheet(sheet.alert.window, returnCode: .abort)
    }

    private final class LinkOpener: NSObject {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        @objc
        func open(_: Any?) {
            NSWorkspace.shared.open(url)
        }
    }

    /// A notice's text: the link starts its own line, so that the text does
    /// not wrap after `https://`.
    nonisolated static func noticeText(_ line: String) -> String {
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        guard let index = words.firstIndex(where: { $0.range(of: "https://", options: .caseInsensitive) != nil }),
              index > 0
        else { return line }
        return words[..<index].joined(separator: " ") + "\n" + words[index...].joined(separator: " ")
    }

    /// The first https link in `line`, without the punctuation around it.
    nonisolated static func link(in line: String) -> URL? {
        for word in line.split(whereSeparator: \.isWhitespace) {
            guard let start = word.range(of: "https://", options: .caseInsensitive)?.lowerBound else { continue }
            let trimmed = word[start...].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>'\""))
            if let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host?.isEmpty == false { return url }
        }
        return nil
    }

    /// A terminal window: the key window can be the quick terminal, a
    /// desktop widget or a popover, which a sheet does not suit.
    static func terminalWindow() -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap(\.self) + NSApp.windows.filter(\.isVisible)
        return candidates.first(where: { AppDelegate.isTerminalWindowCandidate($0) })
    }

    /// The window for a question's sheet: the terminal window, or the sheet
    /// that is open on it. A sheet on a window with a sheet waits until that
    /// sheet closes, and the New Remote Project sheet stays open while its
    /// check waits for the login and the install question (0358).
    static func sheetParent() -> NSWindow? {
        terminalWindow().map(sheetParent(of:))
    }

    /// `window`, or the last sheet that is open on it.
    static func sheetParent(of window: NSWindow) -> NSWindow {
        var parent = window
        while let sheet = parent.attachedSheet {
            parent = sheet
        }
        return parent
    }

    // MARK: - Sheets

    private enum Button {
        static let primary = NSApplication.ModalResponse.alertFirstButtonReturn
        static let cancel = NSApplication.ModalResponse.alertSecondButtonReturn
        static let saved = NSApplication.ModalResponse.alertThirdButtonReturn
    }

    private func presentNext() {
        guard current == nil, !queue.isEmpty else { return refreshNotice() }
        // A question has the window first. Its notice comes back after.
        closeNoticeSheet()
        let pending = queue.removeFirst()
        current = pending
        let request = pending.request
        let savedID = savedEntry(for: request)

        let alert = NSAlert()
        alert.messageText = switch request.kind {
        case .secret: String(localized: "Log In to \(request.host)")
        case .yesNo,
             .confirm: String(localized: "Connect to \(request.host)?")
        }
        let question = Question.of(request.prompt, kind: request.kind)
        var text = question.text
        if SSHPrompt.isRetry(request, answered: answeredSecret) {
            text = question.refusal + "\n" + text
        }
        alert.informativeText = text
        alert.addButton(withTitle: request.kind == .secret
            ? String(localized: "Log In")
            : String(localized: "Connect", comment: "The button that accepts an ssh question, such as a new host key."))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if request.kind == .secret, savedID != nil { alert.addButton(withTitle: String(localized: "Use Saved Password")) }
        let columns = Self.columns(of: alert)
        var field: NSSecureTextField?
        if request.kind == .secret {
            let secure = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: columns.buttons.width, height: 24))
            alert.accessoryView = secure
            alert.window.initialFirstResponder = secure
            field = secure
        } else if case let .hostKey(key) = question {
            let label = NSTextField(labelWithString: "\(key.host)\n\(key.type) \(key.fingerprint)")
            label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.isSelectable = true
            label.lineBreakMode = .byClipping
            label.sizeToFit()
            // A fingerprint is never wrapped: a long one makes the sheet wider.
            label.setFrameOrigin(NSPoint(x: columns.textInset, y: 0))
            let box = NSView(frame: NSRect(
                x: 0,
                y: 0,
                width: max(columns.buttons.width, columns.textInset + label.frame.width),
                height: label.frame.height
            ))
            box.addSubview(label)
            alert.accessoryView = box
        }
        alert.layout()

        guard let window = Self.sheetParent() else {
            NSApp.activate()
            finish(pending, response: alert.runModal(), field: field, savedID: savedID)
            return
        }
        pending.sheet = (alert, window)
        NSApp.activate()
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.finish(pending, response: response, field: field, savedID: savedID)
        }
    }

    /// The columns of an alert. NSAlert puts an accessory at the left edge
    /// of its buttons, and its text a few points in from that edge
    /// (measured on macOS 27: buttons from 16 pt, text from 20 pt). A field
    /// as wide as the buttons, and a label moved in by `textInset`, line up
    /// with both. Call it after the buttons are added.
    private static func columns(of alert: NSAlert) -> (buttons: NSRect, textInset: CGFloat) {
        alert.layout()
        let buttons = alert.buttons.map { $0.convert($0.bounds, to: nil) }.reduce(NSRect.null) { $0.union($1) }
        func text(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == alert.informativeText { return field }
            return view.subviews.lazy.compactMap(text(in:)).first
        }
        let textMinX = alert.window.contentView.flatMap(text(in:)).map { $0.convert($0.bounds, to: nil).minX }
        return (buttons, max(0, (textMinX ?? buttons.minX) - buttons.minX))
    }

    private func finish(_ pending: Pending, response: NSApplication.ModalResponse, field: NSSecureTextField?, savedID: PasswordEntryID?) {
        let request = pending.request
        if request.kind == .secret, response == Button.primary {
            answeredSecret[request.asker] = request.prompt
        }
        let answer: Answer? = switch response {
        case Button.primary: .text(request.kind == .secret ? field?.stringValue ?? "" : request.kind == .yesNo ? "yes" : "")
        case Button.saved: nil
        default: .cancelled
        }
        if let answer {
            settle(pending, answer)
            return
        }
        // Use Saved Password: the click is the request; the authentication
        // is the gate. A refusal shows the question again.
        guard let savedID else { return settle(pending, .cancelled) }
        Task { @MainActor in
            let allowed = await PasswordAuthenticator.shared.authorize(
                reason: String(
                    localized: "autofill the password for “\(request.host)”",
                    comment: "Touch ID reason. macOS shows it after “Macterm is trying to”."
                )
            )
            if allowed, let password = PasswordVault.shared.password(for: savedID) {
                answeredSecret[request.asker] = request.prompt
                settle(pending, .text(password))
            } else if kill(request.sshPID, 0) == 0 {
                current = nil
                queue.insert(pending, at: 0)
                presentNext()
            } else {
                // The master exited while Touch ID was up.
                settle(pending, .cancelled)
            }
        }
    }

    private func settle(_ pending: Pending, _ answer: Answer) {
        let result = answer == .cancelled ? "cancelled" : "answered"
        logger.info("ssh prompt for host=\(pending.request.host, privacy: .public): \(result, privacy: .public)")
        pending.continuation.resume(returning: answer)
        if current === pending { current = nil }
        presentNext()
    }

    /// v1 files a remote project's login under `ssh <destination>` and the
    /// prompt line, so a password saved at a v1 pane's login fills here too.
    private func savedEntry(for request: Request) -> PasswordEntryID? {
        guard Preferences.shared.passwordManagerEnabled else { return nil }
        let id = PasswordEntryID(
            command: "ssh \(request.host)",
            prompt: request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return PasswordVault.shared.contains(id) ? id : nil
    }
}

extension SSHLoginPrompts {
    func askToInstallServer(on host: String) async -> Bool {
        await RemoteServerConsent.ask(host)
    }
}
