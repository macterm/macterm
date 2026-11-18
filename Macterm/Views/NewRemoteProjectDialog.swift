import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: appBundleID, category: "NewRemoteProjectDialog")

/// The host and folder of a new remote project that the palette parsed from
/// a typed `host:folder` (0358). The dialog opens with them and checks at once.
struct NewRemoteProjectDraft: Equatable {
    var host: String
    var directory: String

    /// The draft for a typed scp-style path, nil for any other text.
    init?(path: String) {
        guard case let .remote(user, host, directory) = ProjectPath.parse(path) else { return nil }
        self.host = HostCommands.destination(user: user, host: host)
        self.directory = directory
    }
}

/// "New Project → Remote Machine" (#104), as the same kind of dialog as the
/// install question (`RemoteServerConsent`): an `NSAlert` sheet on the
/// terminal window, with its fields in the accessory view.
///
/// - The fields: a display name, an ssh destination (`[user@]host` or an
///   ssh-config alias; port, identity and ControlMaster live in
///   `~/.ssh/config`) and a remote folder, composed into the scp-style
///   `Project.path` (`ProjectPath.composeRemote`). Add is enabled only for a
///   well-formed remote spec. An empty name is `ProjectPath.remoteDisplayName`,
///   which the name field shows as its placeholder, so it follows the folder.
/// - Add connects to the host as a pane does and adds the project only when
///   the folder is there (`RemoteHosts.checkFolder`, 0358). The buttons have
///   their own actions, so the dialog stays up during the check. A line under
///   the fields says that it connects, or why nothing was added. The line
///   takes room only while it shows, so the buttons sit under the fields
///   when it is empty (0393). After a refusal, Add stays off until an edit.
/// - The install question of the host is the dialog's next step, in the same
///   window (`askInstall`): the content dissolves into the new text and
///   buttons (`crossfade`), and the window resizes with its native animation
///   (`relayout`). In this dialog Escape means Cancel, so the question has
///   no Escape key: Continue Without Server is a click only (0393). A login
///   question shows on top (`SSHLoginPrompts.sheetParent`).
/// - The palette opens it with a `NewRemoteProjectDraft`: the check starts at
///   once, so the next step is the install question, the login or the
///   project.
@MainActor
final class NewRemoteProjectDialog: NSObject, NSTextFieldDelegate {
    /// The open dialog. There is one at a time.
    private(set) static var current: NewRemoteProjectDialog?

    /// The open dialog while it checks `destination`: the install question
    /// of that host is its next step.
    static func checking(_ destination: String) -> NewRemoteProjectDialog? {
        guard let current, current.checkedDestination == destination else { return nil }
        return current
    }

    private enum Step {
        case fields
        case checking
        /// The install question of `host`.
        case install(CheckedContinuation<Bool, Never>, host: String)
    }

    let alert = NSAlert()
    let nameField = NSTextField()
    let hostField = NSTextField()
    let directoryField = NSTextField()
    /// The line under the fields: the connect, or why nothing was added.
    let statusLine = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let form: NSView
    private let grid: NSGridView
    /// The status line starts after the spinner while it turns, else at the
    /// edge.
    private var afterSpinner: NSLayoutConstraint?
    private var atEdge: NSLayoutConstraint?

    private var step = Step.fields
    private var check: Task<Void, Never>?
    private var checkedDestination: String?
    /// Why the last Add added nothing. An edit clears it.
    private var failure: String?
    /// When the install question last closed. Its buttons become Add and
    /// Cancel again: a second click of a double click must not cancel.
    private var installAnswered = ContinuousClock.now - .seconds(60)
    private static let doubleClickGuard: Duration = .milliseconds(500)

    /// The check: nil when the folder is there, else the line that says why
    /// nothing is added (`RemoteHosts.refusal`). Tests answer it.
    private let refusal: @MainActor (String) async -> String?
    /// Adds the project, named and at the path.
    private let create: @MainActor (String, String) -> Void
    /// Asks the install question on its own sheet, after the dialog closed.
    private let askAlone: @MainActor (String) async -> Bool

    /// The space between the fields and a shown status line.
    private static let statusGap: CGFloat = 10

    init(
        draft: NewRemoteProjectDraft? = nil,
        refusal: @escaping @MainActor (String) async -> String? = { await RemoteHosts.shared.refusal(forNewProjectPath: $0) },
        askAlone: @escaping @MainActor (String) async -> Bool = { await RemoteServerConsent.ask($0) },
        create: @escaping @MainActor (String, String) -> Void
    ) {
        self.refusal = refusal
        self.create = create
        self.askAlone = askAlone
        form = NSView()
        let labels = [String(localized: "Name"), String(localized: "Host"), String(localized: "Directory")]
            .map { NSTextField(labelWithString: $0) }
        grid = NSGridView(views: zip(labels, [nameField, hostField, directoryField]).map { [$0, $1] })
        super.init()
        hostField.stringValue = draft?.host ?? ""
        directoryField.stringValue = draft?.directory ?? "~"
        hostField.placeholderString = String(localized: "[user@]host or ssh alias")
        directoryField.placeholderString = "~/dev/api"
        for field in [nameField, hostField, directoryField] {
            field.delegate = self
            field.lineBreakMode = .byTruncatingTail
            field.cell?.isScrollable = true
        }
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        for (index, button) in alert.buttons.enumerated() {
            button.target = self
            button.action = index == 0 ? #selector(primary) : #selector(secondary)
        }
        buildForm()
        show(.fields)
    }

    /// Opens the dialog as a sheet on `window`, or on the last sheet open
    /// on it (nil in tests: no window). An open dialog closes first: there
    /// is one at a time. With a draft, the check starts at once.
    func present(on window: NSWindow?, startCheck: Bool) {
        Self.current?.close()
        Self.current = self
        if let window {
            NSApp.activate()
            // A sheet that ends with no click of ours (its window closed)
            // ends the dialog too, so no check waits on a dialog that is gone.
            alert.beginSheetModal(for: SSHLoginPrompts.sheetParent(of: window)) { [weak self] _ in
                guard let self, Self.current === self else { return }
                close()
            }
            focusFirstField()
        }
        if startCheck { add() }
    }

    private func focusFirstField() {
        let field = hostField.stringValue.isEmpty ? hostField : nameField
        alert.window.initialFirstResponder = field
        alert.window.makeFirstResponder(field)
    }

    // MARK: - Steps

    private var composedPath: String? {
        ProjectPath.composeRemote(host: hostField.stringValue, directory: directoryField.stringValue)
    }

    private var trimmedName: String {
        nameField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    /// A typed name that a sentinel workspace reserves
    /// (`Project.reservedNameMessage`).
    private var reservedNameMessage: String? {
        Project.reservedNameMessage(for: nameField.stringValue)
    }

    /// The name of a project that the user did not name, as the palette
    /// shows it: from the parsed host, with no user.
    private var automaticName: String {
        guard let path = composedPath, case let .remote(_, host, directory) = ProjectPath.parse(path) else {
            return "devbox"
        }
        return ProjectPath.remoteDisplayName(host: host, directory: directory)
    }

    /// The line under the fields. Read by tests.
    var statusText: String {
        statusLine.stringValue
    }

    var isChecking: Bool {
        if case .checking = step { true } else { false }
    }

    var isAskingInstall: Bool {
        if case .install = step { true } else { false }
    }

    private func add() {
        guard let path = composedPath, reservedNameMessage == nil, case .fields = step else { return }
        guard case let .remote(user, host, _) = ProjectPath.parse(path) else { return }
        let name = trimmedName.isEmpty ? automaticName : trimmedName
        failure = nil
        checkedDestination = HostCommands.destination(user: user, host: host)
        show(.checking)
        check = Task { [weak self, refusal] in
            let answer = await refusal(path)
            guard let self, !Task.isCancelled else { return }
            check = nil
            checkedDestination = nil
            if let answer {
                logger.info("new remote project \(path, privacy: .public): not added")
                failure = answer
                show(.fields)
                focusFirstField()
                return
            }
            create(name, path)
            close()
        }
    }

    /// The install question of the host that this dialog checks, as its
    /// next step. The answer goes back to the check (`RemoteServerConsent`).
    func askInstall() async -> Bool {
        guard case .checking = step, let destination = checkedDestination else { return false }
        return await withCheckedContinuation { continuation in
            show(.install(continuation, host: destination))
        }
    }

    @objc
    private func primary() {
        switch step {
        case .fields: add()
        case .checking: break
        case let .install(continuation, _):
            installAnswered = .now
            show(.checking)
            continuation.resume(returning: true)
        }
    }

    @objc
    private func secondary() {
        switch step {
        case .fields:
            close()
        case .checking:
            guard ContinuousClock.now - installAnswered > Self.doubleClickGuard else { return }
            close()
        case let .install(continuation, _):
            installAnswered = .now
            show(.checking)
            continuation.resume(returning: false)
        }
    }

    /// Ends the dialog, and its check adds nothing. The connect of the
    /// host goes on for its panes, so an install question that waits is not
    /// answered here: it goes to its own sheet (`RemoteServerConsent`), and
    /// the user still decides. No decline is kept that the user did not
    /// choose.
    func close() {
        check?.cancel()
        check = nil
        checkedDestination = nil
        let question = step
        step = .fields
        if Self.current === self { Self.current = nil }
        if alert.window.isSheet { alert.window.sheetParent?.endSheet(alert.window) }
        if case let .install(continuation, host) = question {
            Task { [askAlone] in await continuation.resume(returning: askAlone(host)) }
        }
    }

    // MARK: - Layout

    private func show(_ next: Step) {
        let wasInstall = isAskingInstall
        step = next
        if wasInstall != isAskingInstall { crossfade() }
        let primaryButton = alert.buttons[0]
        let secondaryButton = alert.buttons[1]
        if case let .install(_, installHost) = next {
            alert.messageText = RemoteServerConsent.title(installHost)
            alert.informativeText = RemoteServerConsent.text
            // NSAlert keeps an old accessory in its window: remove it.
            alert.accessoryView = nil
            form.removeFromSuperview()
            primaryButton.title = RemoteServerConsent.installButton
            secondaryButton.title = RemoteServerConsent.withoutServerButton
            secondaryButton.keyEquivalent = ""
            primaryButton.isEnabled = true
            relayout()
            return
        }
        alert.messageText = String(localized: "New Remote Project")
        alert.informativeText = String(localized: "Port, identity, and ControlMaster come from ~/.ssh/config.")
        alert.accessoryView = form
        primaryButton.title = String(localized: "Add")
        secondaryButton.title = String(localized: "Cancel")
        secondaryButton.keyEquivalent = "\u{1b}"
        for field in [nameField, hostField, directoryField] {
            field.isEnabled = !isChecking
        }
        refresh()
        relayout()
    }

    /// The parts that follow the fields: the name's placeholder, Add, and
    /// the status line.
    private func refresh() {
        nameField.placeholderString = automaticName
        if isChecking {
            let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
            statusLine.stringValue = String(localized: "Connecting to \(host)…")
            statusLine.textColor = .secondaryLabelColor
            spinner.isHidden = false
            spinner.startAnimation(nil)
            atEdge?.isActive = false
            afterSpinner?.isActive = true
            alert.buttons[0].isEnabled = false
            fitForm()
            return
        }
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        afterSpinner?.isActive = false
        atEdge?.isActive = true
        let message = reservedNameMessage ?? failure
        statusLine.stringValue = message ?? ""
        // The line has room for two lines; the whole text is in the tooltip.
        statusLine.toolTip = message
        statusLine.textColor = NSColor(MactermTheme.warning)
        // A refused path stays refused until an edit: Add and Return do nothing.
        alert.buttons[0].isEnabled = composedPath != nil && reservedNameMessage == nil && failure == nil
        fitForm()
    }

    func controlTextDidChange(_: Notification) {
        let height = form.frame.height
        failure = nil
        refresh()
        if form.frame.height != height { relayout() }
    }

    /// The step change between the fields and the install question: the
    /// old content dissolves into the new (a Core Animation fade on the
    /// window's content layer). A dissolve is what Reduce Motion keeps, so
    /// it stays on with Reduce Motion.
    private func crossfade() {
        guard alert.window.isVisible, let view = alert.window.contentView else { return }
        view.wantsLayer = true
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        view.layer?.add(fade, forKey: "step")
    }

    /// Lays the alert out again. A visible window moves to the frame that
    /// the alert gives it with the native animation
    /// (`NSWindow.setFrame(_:display:animate:)`), unless Reduce Motion is on.
    private func relayout() {
        let window = alert.window
        let old = window.frame
        alert.layout()
        guard window.isVisible else { return }
        let new = window.frame
        guard new != old else { return }
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(old, display: false)
        window.setFrame(new, display: true, animate: animate)
    }

    /// Three labeled fields and the status line, as wide as the alert's
    /// row of buttons: a wider accessory makes the alert wider than its
    /// buttons (0384).
    private func buildForm() {
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        statusLine.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLine.maximumNumberOfLines = 2
        statusLine.translatesAutoresizingMaskIntoConstraints = false

        alert.layout()
        let buttons = alert.buttons.map { $0.convert($0.bounds, to: nil) }.reduce(NSRect.null) { $0.union($1) }
        let width = buttons.width
        form.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        form.addSubview(grid)
        form.addSubview(spinner)
        form.addSubview(statusLine)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: form.topAnchor),
            grid.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            spinner.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            spinner.topAnchor.constraint(equalTo: statusLine.topAnchor),
            statusLine.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: Self.statusGap),
            statusLine.trailingAnchor.constraint(equalTo: form.trailingAnchor),
        ])
        afterSpinner = statusLine.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6)
        atEdge = statusLine.leadingAnchor.constraint(equalTo: form.leadingAnchor)
        atEdge?.isActive = true
    }

    /// Gives the form its height: the fields, and the status line only when
    /// it has text. The line wraps at the width of the form, not at its own
    /// text (0393). A fixed frame: NSAlert places its accessory by frame.
    private func fitForm() {
        let width = form.frame.width
        var height = grid.fittingSize.height
        if !statusLine.stringValue.isEmpty {
            let indent = isChecking ? spinner.fittingSize.width + 6 : 0
            statusLine.preferredMaxLayoutWidth = width - indent
            height += Self.statusGap + statusLine.fittingSize.height
        }
        form.setFrameSize(NSSize(width: width, height: height))
    }
}
