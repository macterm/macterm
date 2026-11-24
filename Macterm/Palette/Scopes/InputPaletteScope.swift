import Foundation

/// A screen that asks for one value: the field holds the value, not a
/// search. It is the step of an action that needs text from the user (a
/// name, a path), so that the action stays in the palette and needs no
/// sheet.
///
/// The field starts on `initialValue`, selected, so a keystroke replaces
/// it. Return commits the text in the field. The rows under the field are
/// completions: Tab or a click puts the selected one in the field, and
/// never commits. Over the completions, `actions` are rows that do
/// something in place of the typed value (Select in Finder): a click runs
/// one, and so does Return while one is selected and the field is empty.
/// Escape, or Backspace at an empty field, pops the screen like any screen.
/// A commit that `commit` refuses keeps the screen and shows the reason as
/// one line above the rows, until the text changes.
///
/// A screen with `results` shows them in place of completions: rows that
/// run, as the root's rows do. The top result is selected, and Return runs
/// the selected result. Tab fills the field with the first completion, from
/// the selected row down, that changes the field. Return commits the field
/// only when no result is selected.
///
/// The pill of an input screen is its `title` alone, with no icon.
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
    /// Rows above the completions that do something in place of the typed
    /// value, in order.
    let actions: [PaletteInputAction]
    /// The completions of the text in the field, best first.
    let completions: @MainActor (String) -> [PaletteCompletion]
    /// Rows that run, for the text in the field, best first. When set, the
    /// screen shows them and not `completions`.
    let results: (@MainActor (String, PaletteContext) -> [PaletteInputResult])?
    /// Do the action with the text in the field, or refuse it. On `.done`
    /// the palette closes. An action that must run after the palette has
    /// closed and focus is back in the pane sets `AppState.postPaletteAction`.
    let commit: @MainActor (String, PaletteContext) -> PaletteCommit

    init(
        id: String,
        title: String,
        prompt: String,
        initialValue: String = "",
        summary: String = "",
        actions: [PaletteInputAction] = [],
        completions: @escaping @MainActor (String) -> [PaletteCompletion] = { _ in [] },
        results: (@MainActor (String, PaletteContext) -> [PaletteInputResult])? = nil,
        commit: @escaping @MainActor (String, PaletteContext) -> PaletteCommit
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.initialValue = initialValue
        self.summary = summary
        self.actions = actions
        self.completions = completions
        self.results = results
        self.commit = commit
    }

    var pill: PalettePill { PalettePill(title: title) }

    static func == (lhs: PaletteInput, rhs: PaletteInput) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Completions for a field that holds a local directory
    /// (`PathCompleter`): the directories under the typed path, each by
    /// its name. A remote spec gets none.
    @MainActor
    static func pathCompletions(_ text: String) -> [PaletteCompletion] {
        guard let completion = PathCompleter.complete(text) else { return [] }
        return completion.children.map { child in
            PaletteCompletion(
                title: (child as NSString).lastPathComponent,
                value: PathCompleter.fieldText(for: child, typed: text)
            )
        }
    }
}

/// A row of an input screen that does something in place of the typed
/// value. It runs after the palette has closed (`AppState.postPaletteAction`),
/// so that it can show a modal panel or a sheet.
struct PaletteInputAction {
    let id: String
    let title: String
    let icon: PaletteIcon
    let run: @MainActor (PaletteContext) -> Void
}

/// A row of an input screen that runs (`PaletteInput.results`): the row, and
/// the text that Tab puts in the field for it, nil for none.
struct PaletteInputResult {
    let item: PaletteItem
    let completion: String?
}

/// A row under an input field: what it shows, and the text the field takes
/// when the row is picked.
struct PaletteCompletion: Equatable {
    let title: String
    let value: String
}

/// What a commit of an input screen did.
enum PaletteCommit: Equatable {
    /// The action ran; the palette closes.
    case done
    /// The value is not allowed; the screen stays and shows the reason.
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
    /// The text that the shown refusal was for: the line goes when the text
    /// changes.
    private var refusedText: String?
    private var completions: [PaletteCompletion] = []
    private var results: [PaletteInputResult] = []
    /// True until the screen has shown once: only then does the panel
    /// select the field's text, the initial value.
    var isFirstShow = true

    init(input: PaletteInput) {
        self.input = input
        text = input.initialValue
    }

    var placeholder: String { input.prompt }
    var initialQuery: String { text }

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        text = query.raw
        if failure != nil, text != refusedText {
            failure = nil
            refusedText = nil
        }
        let actions = input.actions.map { action in
            PaletteItem(id: Self.actionID(action), title: action.title, icon: action.icon) {
                context.appState.postPaletteAction = { action.run(context) }
            }
        }
        let actionSection = actions.isEmpty ? [] : [PaletteSection(header: nil, items: actions)]
        if let makeResults = input.results {
            completions = []
            results = makeResults(text, context)
            let items = results.map(\.item)
            return actionSection + (items.isEmpty ? [] : [PaletteSection(header: nil, items: items)])
        }
        results = []
        completions = input.completions(text)
        let items = completions.map { PaletteItem(id: Self.itemID($0), title: $0.title, action: {}) }
        return actionSection + (items.isEmpty ? [] : [PaletteSection(header: nil, items: items)])
    }

    /// True when `item`, a row of this screen, is one of its `results`:
    /// Return and a click run it.
    func isResult(_ item: PaletteItem) -> Bool {
        results.contains { $0.item.id == item.id }
    }

    /// True when `item`, a row of this screen, is one of its `actions`:
    /// picking it runs the row, not a completion.
    func isAction(_ item: PaletteItem) -> Bool {
        input.actions.contains { Self.actionID($0) == item.id }
    }

    /// The text that `item`, a row of this screen, puts in the field.
    func completion(for item: PaletteItem) -> String? {
        if let result = results.first(where: { $0.item.id == item.id }) { return result.completion }
        return completions.first { Self.itemID($0) == item.id }?.value
    }

    /// Commit `text`. True when the palette closes; false when the value
    /// was refused, and `failure` has the reason.
    func commit(_ text: String, context: PaletteContext) -> Bool {
        switch input.commit(text, context) {
        case .done:
            failure = nil
            refusedText = nil
            return true
        case let .refused(reason):
            failure = PaletteFailure(title: reason, retryable: false)
            refusedText = text
            return false
        }
    }

    private static func itemID(_ completion: PaletteCompletion) -> String {
        "completion:\(completion.value)"
    }

    private static func actionID(_ action: PaletteInputAction) -> String {
        "action:\(action.id)"
    }
}
