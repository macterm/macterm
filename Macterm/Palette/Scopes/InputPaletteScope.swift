import Foundation

/// A screen that asks for one value: the field holds the value, not a
/// search. It is the step of an action that needs text from the user (a
/// name, a path), so that the action stays in the palette and needs no
/// sheet.
///
/// The field starts on `initialValue`, selected, so a keystroke replaces
/// it. Under the field, `check` gives for the typed text either one action
/// row (`Rename to "build"`), a notice that says why the text is not valid,
/// or nothing. The action row is the first row and is selected, so a typed
/// value and Return run it. **Return runs the action only when the action
/// row is the selected row** (Ethan, 0578): with no row selected, Return
/// does nothing, and the field text is never committed in another way.
/// The rows under the action row are completions: Return, Tab or a click
/// puts one in the field, and never runs the action. A screen can instead
/// give rows that are actions themselves (`choices`, folder rows): the
/// selection rests on the first one, Return or a click runs the selected
/// one, and Tab puts its folder in the field. Escape, or Backspace
/// at an empty field, pops the screen like any screen. An action that
/// refuses when it runs keeps the screen and shows the reason, until the
/// text changes. An action that must ask first (a host checks a folder)
/// has a `check`: the screen shows its message as the notice until the
/// answer comes, and an edit of the field cancels it.
///
/// The pill of an input screen is its `title` alone, with no icon (Ethan,
/// 0561).
///
/// While the field is empty, a Cancel row comes last. Return on it leaves
/// the screen as Escape does. The selection rests on it when there is no
/// action row, so Return on an empty field does no action by chance.
///
/// Its identity is `id`: two inputs with one id are one screen to the
/// palette (a chord toggles it). An input about one thing (a tab, a pane)
/// puts that thing's id in its own, so that two targets are two screens.
struct PaletteInput: Hashable {
    let id: String
    /// The pill's text.
    let title: String
    /// The field's placeholder: what to type.
    let prompt: String
    let initialValue: String
    /// What the screen is for, starting with a verb: the subtitle of the
    /// palette row that opens it.
    let summary: String
    /// The completions of the text in the field, best first.
    let completions: @MainActor (String) -> [PaletteCompletion]
    /// The rows that are actions themselves, best first: Return or a click
    /// on one runs it, and Tab puts its `value` in the field. A folder
    /// screen gives the folder rows here, so that a folder row is the
    /// action (Ethan, 0594).
    let choices: @MainActor (String, PaletteContext) -> [PaletteInputChoice]
    /// What the text in the field gives: the action row when the value is
    /// valid, the notice when it is not, or nothing (an empty field, or a
    /// text whose rows are `choices`). It
    /// gets the palette's context, so that an action can reach the app and
    /// the projects.
    let check: @MainActor (String, PaletteContext) -> PaletteInputCheck
    /// The host's folder listings of a remote folder field (0614). Its
    /// listings come after a keystroke, so the screen draws again when one
    /// comes, and stops the requests when it leaves. nil for any other
    /// field.
    let hostFolders: HostFolderLister?

    init(
        id: String,
        title: String,
        prompt: String,
        initialValue: String = "",
        summary: String = "",
        completions: @escaping @MainActor (String) -> [PaletteCompletion] = { _ in [] },
        choices: @escaping @MainActor (String, PaletteContext) -> [PaletteInputChoice] = { _, _ in [] },
        hostFolders: HostFolderLister? = nil,
        check: @escaping @MainActor (String, PaletteContext) -> PaletteInputCheck
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.initialValue = initialValue
        self.summary = summary
        self.completions = completions
        self.choices = choices
        self.hostFolders = hostFolders
        self.check = check
    }

    var pill: PalettePill { PalettePill(title: title) }

    static func == (lhs: PaletteInput, rhs: PaletteInput) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// What the text of an input field gives (`PaletteInput.check`).
enum PaletteInputCheck {
    /// The value is valid: the screen shows this action row first.
    case action(PaletteInputAction)
    /// The value is not valid: the screen shows this notice and no action
    /// row.
    case notice(String)
    /// No action row and no notice, as for an empty field.
    case nothing
}

/// What a press of a row of an input screen did (`InputPaletteScope.press`).
enum PaletteInputPress: Equatable {
    /// Nothing: no row, or a completion that the field already has.
    case nothing
    /// The field takes this text.
    case fill(String)
    /// The action ran; the palette closes.
    case closed
    /// The action refused; the screen stays and shows the reason.
    case refused
    /// The Cancel row: the screen goes, as with Escape.
    case cancelled
    /// The action waits for its check (`PaletteInputAction.check`): the
    /// screen shows `loading`, and closes or shows the reason when the
    /// answer comes.
    case checking
    /// A choice that opens another screen (`PaletteItem.opensScope`).
    case opens(PaletteScopeID)
}

/// The one action row of an input screen: its title names the action and
/// the value (`Rename to "build"`). It has no icon (Ethan, 0561).
struct PaletteInputAction {
    let title: String
    /// A path that the row shows under its title, when the title does not
    /// name the value (`Current Pane's Directory`). The row cuts it in the
    /// middle, so that both ends stay.
    var subtitle: String?
    /// A check that takes time (a host checks a remote folder), with the
    /// line that the screen shows while it runs. Its answer is nil when the
    /// action can run, else the refusal. A `retryable` refusal (no
    /// connection) has Retry, which runs the check again. Nil for an action
    /// with no such check.
    var check: PaletteInputCheckStep?
    /// Do the action, or refuse it. On `.done` the palette closes. An
    /// action that must run after the palette has closed and focus is back
    /// in the pane sets `AppState.postPaletteAction`.
    let run: @MainActor () -> PaletteCommit

    init(
        title: String,
        subtitle: String? = nil,
        check: PaletteInputCheckStep? = nil,
        run: @escaping @MainActor () -> PaletteCommit
    ) {
        self.title = title
        self.subtitle = subtitle
        self.check = check
        self.run = run
    }
}

/// The check of an action that takes time (`PaletteInputAction.check`).
struct PaletteInputCheckStep {
    /// What the screen shows while the check runs.
    let message: String
    /// Nil when the action can run, else the refusal.
    let answer: @MainActor () async -> PaletteFailure?
}

/// A row of an input screen that is an action itself
/// (`PaletteInput.choices`): Return or a click runs the action of `item`
/// and closes the palette. Tab puts `value` in the field, when it has one.
struct PaletteInputChoice {
    let item: PaletteItem
    let value: String?
}

/// A row under an input field: what it shows, and the text the field takes
/// when the row is picked.
struct PaletteCompletion: Equatable {
    let title: String
    let value: String
    /// A path row's subtitle (`PathRow`), cut in the middle when long.
    var subtitle: String?
}

/// What the run of an input screen's action did.
enum PaletteCommit: Equatable {
    /// The action ran; the palette closes.
    case done
    /// The action cannot run; the screen stays and shows the reason.
    case refused(String)
}

/// The scope of an input screen (`PaletteInput`). It keeps the text of its
/// field, so that the field has it again when the screen comes back to the
/// top of the stack.
@MainActor
final class InputPaletteScope: PaletteScope {
    let input: PaletteInput
    private(set) var text: String
    private(set) var failure: PaletteFailure?
    /// The action row of the text, nil when the text is not valid.
    private(set) var action: PaletteInputAction?
    /// The reason of an action that refused, and the text it was for: the
    /// line goes when the text changes.
    private var refusal: Refusal?

    /// An action that refused, for the text it refused: the action is kept
    /// when a retry can run its check again.
    private struct Refusal {
        let text: String
        let failure: PaletteFailure
        let action: PaletteInputAction?
    }

    private var completions: [PaletteCompletion] = []
    private var choices: [PaletteInputChoice] = []
    /// True until the screen has shown once: only then does the panel
    /// select the field's text, the initial value.
    var isFirstShow = true
    /// The check of an action in flight (`PaletteInputAction.check`).
    private var checkTask: Task<Void, Never>?
    /// The line of an action's check in flight (`PaletteInputAction.check`).
    private var checkLoading: PaletteLoading?
    /// An action ran after its check: the panel closes the palette at its
    /// next redraw (`takeCloseRequest`).
    private var closeRequested = false
    /// The text that the check in flight is for.
    private var checkedText: String?
    private var onChange: (@MainActor () -> Void)?

    /// The id of the action row.
    static let actionItemID = "input-action"
    /// The id of the Cancel row.
    static let cancelItemID = "input-cancel"

    init(input: PaletteInput) {
        self.input = input
        text = input.initialValue
    }

    func activate(context _: PaletteContext, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        input.hostFolders?.onChange = onChange
    }

    func deactivate() {
        cancelCheck()
        input.hostFolders?.cancel()
        input.hostFolders?.onChange = nil
    }

    private func cancelCheck() {
        checkTask?.cancel()
        checkTask = nil
        checkedText = nil
        checkLoading = nil
    }

    /// True once, after an action ran when its check said yes: the palette
    /// closes.
    func takeCloseRequest() -> Bool {
        defer { closeRequested = false }
        return closeRequested
    }

    /// An action's check in flight, or a host listing in flight. The panel
    /// reads it after `sections`, which is where a listing starts.
    /// `onChange` redraws when either ends. A check has no action row, so
    /// it shows as the notice. A listing shows as the spinner of the field.
    var loading: PaletteLoading? {
        if let checkLoading { return checkLoading }
        return input.hostFolders?.isListing == true ? PaletteLoading(message: String(localized: "Listing folders…")) : nil
    }

    var placeholder: String { input.prompt }
    var initialQuery: String { text }

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        text = query.raw
        // A check is for the text it started on: new text stops it, so
        // that its answer never runs the action of the old text.
        if checkTask != nil, checkedText != text { cancelCheck() }
        if let refusal, refusal.text != text { self.refusal = nil }
        action = nil
        var notice: String?
        switch input.check(text, context) {
        case let .action(row): action = row
        case let .notice(text): notice = text
        case .nothing: break
        }
        // A refusal that can change (no connection) goes when the screen
        // has a newer answer for the text, such as a host's notice.
        if let refusal, refusal.failure.retryable, notice != nil { self.refusal = nil }
        // While a check runs, and while a refusal stands for this text, the
        // action row is not offered: the message is then alone and fills
        // the results, as the notice of a value that is not valid does. A
        // refusal that can change (no connection) has Retry instead.
        if checkLoading != nil || refusal != nil { action = nil }
        if checkLoading != nil {
            failure = nil
        } else if let refusal {
            failure = refusal.failure
        } else if let reason = notice {
            failure = PaletteFailure(title: reason, retryable: false)
        } else {
            failure = nil
        }
        completions = input.completions(text)
        choices = input.choices(text, context)
        var items = choices.map(\.item) + completions.map {
            PaletteItem(id: Self.itemID($0), title: $0.title, subtitle: $0.subtitle, subtitleIsPath: $0.subtitle != nil, action: {})
        }
        if let action {
            items.insert(
                PaletteItem(
                    id: Self.actionItemID,
                    title: action.title,
                    subtitle: action.subtitle,
                    subtitleIsPath: true,
                    action: {}
                ),
                at: 0
            )
        }
        if text.isEmpty {
            items.append(PaletteItem(id: Self.cancelItemID, title: String(localized: "Cancel"), action: {}))
        }
        return items.isEmpty ? [] : [PaletteSection(header: nil, items: items)]
    }

    /// Whether `item` is the action row of this screen.
    func isAction(_ item: PaletteItem) -> Bool {
        action != nil && item.id == Self.actionItemID
    }

    /// Whether `item` is a row of `PaletteInput.choices`.
    func isChoice(_ item: PaletteItem) -> Bool {
        choices.contains { $0.item.id == item.id }
    }

    /// The id of the row where the selection rests on a new list: the
    /// action row, else the first choice, else the Cancel row of an empty
    /// field, else no row.
    var restingItemID: String? {
        if action != nil { return Self.actionItemID }
        if let first = choices.first { return first.item.id }
        return text.isEmpty ? Self.cancelItemID : nil
    }

    /// The text that `item`, a completion row or a choice of this screen,
    /// puts in the field.
    func completion(for item: PaletteItem) -> String? {
        if let choice = choices.first(where: { $0.item.id == item.id }) { return choice.value }
        return completions.first { Self.itemID($0) == item.id }?.value
    }

    /// What Tab puts in the field: the value of the selected row, else the
    /// first value of `rows`. A value that the field already has is skipped,
    /// so a second Tab on a folder goes into it. Nil when no row gives a new
    /// value.
    func tabText(selected item: PaletteItem?, rows: [PaletteItem]) -> String? {
        if let item, let value = completion(for: item), value != text { return value }
        return rows.lazy.compactMap { self.completion(for: $0) }.first { $0 != self.text }
    }

    /// What Return or a click on `item` does, with `item` nil when no row
    /// is selected. The action row and a choice run their action. The
    /// Cancel row leaves the screen. A completion row gives its text for
    /// the field. No row, or the text that the field already has, does
    /// nothing.
    func press(_ item: PaletteItem?) -> PaletteInputPress {
        guard let item else { return .nothing }
        if item.id == Self.cancelItemID, text.isEmpty { return .cancelled }
        if let choice = choices.first(where: { $0.item.id == item.id }) {
            if let next = choice.item.opensScope { return .opens(next) }
            choice.item.action()
            return .closed
        }
        guard isAction(item), let action else {
            guard let completion = completion(for: item), completion != text else { return .nothing }
            return .fill(completion)
        }
        if let check = action.check {
            guard checkTask == nil else { return .nothing }
            startCheck(check, of: action)
            return .checking
        }
        return run(action)
    }

    /// Retry and ⌘R on a refusal that can change: run the check of its
    /// action again.
    func retry() {
        guard checkTask == nil, let refusal, refusal.failure.retryable,
              let action = refusal.action, let check = action.check
        else { return }
        startCheck(check, of: action)
        onChange?()
    }

    /// Run `check`, then `action` when it says yes, else show its reason.
    /// The text that the check is for keeps the reason: the line goes
    /// when the text changes.
    private func startCheck(_ check: PaletteInputCheckStep, of action: PaletteInputAction) {
        let checkedText = text
        self.checkedText = checkedText
        checkLoading = PaletteLoading(message: check.message)
        refusal = nil
        failure = nil
        self.action = nil
        checkTask = Task { [weak self] in
            let refused = await check.answer()
            guard let self, !Task.isCancelled, self.checkedText == checkedText else { return }
            checkTask = nil
            self.checkedText = nil
            checkLoading = nil
            if let refused {
                refusal = Refusal(text: checkedText, failure: refused, action: action)
                failure = refused
            } else if run(action) == .closed {
                closeRequested = true
            }
            onChange?()
        }
    }

    private func run(_ action: PaletteInputAction) -> PaletteInputPress {
        switch action.run() {
        case .done:
            refusal = nil
            failure = nil
            return .closed
        case let .refused(reason):
            let refused = PaletteFailure(title: reason, retryable: false)
            refusal = Refusal(text: text, failure: refused, action: nil)
            failure = refused
            return .refused
        }
    }

    private static func itemID(_ completion: PaletteCompletion) -> String {
        "completion:\(completion.value)"
    }
}
