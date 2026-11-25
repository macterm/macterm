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
/// puts one in the field, and never runs the action. Escape, or Backspace
/// at an empty field, pops the screen like any screen. An action that
/// refuses when it runs keeps the screen and shows the reason, until the
/// text changes.
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
    /// What the text in the field gives: the action row when the value is
    /// valid, the notice when it is not, or nothing (an empty field). It
    /// gets the palette's context, so that an action can reach the app and
    /// the projects.
    let check: @MainActor (String, PaletteContext) -> PaletteInputCheck

    init(
        id: String,
        title: String,
        prompt: String,
        initialValue: String = "",
        summary: String = "",
        completions: @escaping @MainActor (String) -> [PaletteCompletion] = { _ in [] },
        check: @escaping @MainActor (String, PaletteContext) -> PaletteInputCheck
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.initialValue = initialValue
        self.summary = summary
        self.completions = completions
        self.check = check
    }

    var pill: PalettePill { PalettePill(title: title) }

    static func == (lhs: PaletteInput, rhs: PaletteInput) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Completions for a field that holds a local directory
    /// (`PathCompleter`): the directories under the typed path, as the rows
    /// of `PathRow`, with `action` as the words before the path. A remote
    /// spec gets none.
    @MainActor
    static func pathCompletions(_ text: String, action: PathRow.Action) -> [PaletteCompletion] {
        guard let completion = PathCompleter.complete(text) else { return [] }
        return completion.children.map { child in
            PaletteCompletion(
                title: PathRow.title(for: child),
                value: PathCompleter.fieldText(for: child, typed: text),
                subtitle: action.subtitle(for: child)
            )
        }
    }

    /// The check of a field that holds a local folder: nothing for an
    /// empty field, the notice of `PathProblem` for a path that is not a
    /// folder, else the action row that `action` makes for the typed text.
    @MainActor
    static func folderCheck(
        _ text: String,
        action: (String) -> PaletteInputAction
    ) -> PaletteInputCheck {
        let path = text.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return .nothing }
        if let problem = PathProblem.local(atPath: path) { return .notice(problem.notice(for: path)) }
        return .action(action(path))
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
}

/// The one action row of an input screen: its title names the action and
/// the value (`Change to "~/work/api"`). It has no icon (Ethan, 0561).
struct PaletteInputAction {
    let title: String
    /// Do the action, or refuse it. On `.done` the palette closes. An
    /// action that must run after the palette has closed and focus is back
    /// in the pane sets `AppState.postPaletteAction`.
    let run: @MainActor () -> PaletteCommit
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
    private var refusal: (text: String, reason: String)?
    private var completions: [PaletteCompletion] = []
    /// True until the screen has shown once: only then does the panel
    /// select the field's text, the initial value.
    var isFirstShow = true

    /// The id of the action row.
    static let actionItemID = "input-action"
    /// The id of the Cancel row.
    static let cancelItemID = "input-cancel"

    init(input: PaletteInput) {
        self.input = input
        text = input.initialValue
    }

    var placeholder: String { input.prompt }
    var initialQuery: String { text }

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        text = query.raw
        if let refusal, refusal.text != text { self.refusal = nil }
        action = nil
        var notice: String?
        switch input.check(text, context) {
        case let .action(row): action = row
        case let .notice(text): notice = text
        case .nothing: break
        }
        if let reason = refusal?.reason ?? notice {
            failure = PaletteFailure(title: reason, retryable: false)
        } else {
            failure = nil
        }
        completions = input.completions(text)
        var items = completions.map {
            PaletteItem(id: Self.itemID($0), title: $0.title, subtitle: $0.subtitle, subtitleIsPath: $0.subtitle != nil, action: {})
        }
        if let action {
            items.insert(PaletteItem(id: Self.actionItemID, title: action.title, action: {}), at: 0)
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

    /// The id of the row where the selection rests on a new list: the
    /// action row, else the Cancel row of an empty field, else no row.
    var restingItemID: String? {
        if action != nil { return Self.actionItemID }
        return text.isEmpty ? Self.cancelItemID : nil
    }

    /// The text that `item`, a completion row of this screen, puts in the
    /// field.
    func completion(for item: PaletteItem) -> String? {
        completions.first { Self.itemID($0) == item.id }?.value
    }

    /// What Return or a click on `item` does, with `item` nil when no row
    /// is selected. The action row runs its action. The Cancel row leaves
    /// the screen. A completion row gives its text for the field. No row,
    /// or the text that the field already has, does nothing.
    func press(_ item: PaletteItem?) -> PaletteInputPress {
        guard let item else { return .nothing }
        if item.id == Self.cancelItemID, text.isEmpty { return .cancelled }
        guard isAction(item), let action else {
            guard let completion = completion(for: item), completion != text else { return .nothing }
            return .fill(completion)
        }
        switch action.run() {
        case .done:
            refusal = nil
            failure = nil
            return .closed
        case let .refused(reason):
            refusal = (text, reason)
            failure = PaletteFailure(title: reason, retryable: false)
            return .refused
        }
    }

    private static func itemID(_ completion: PaletteCompletion) -> String {
        "completion:\(completion.value)"
    }
}
