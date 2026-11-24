import Foundation

/// A screen that asks for one value: the field holds the value, not a
/// search. It is the step of an action that needs text from the user (a
/// name, a path), so that the action stays in the palette and needs no
/// sheet.
///
/// The field starts on `initialValue`, selected, so a keystroke replaces
/// it. Return commits the text in the field, or the value of the selected
/// row when an arrow key selected one. At an empty field the top row is
/// selected, and Return takes it: the rows at an empty field are offers,
/// and an empty field has no value to commit. The rows under the field are
/// completions: Tab or a click puts the selected one in the field, and
/// never commits. Escape, or Backspace at an empty field, pops the screen
/// like any screen. A commit that `commit` refuses keeps the screen and
/// shows the reason as one line above the rows, until the text changes.
///
/// Its identity is `id`: two inputs with one id are one screen to the
/// palette (a chord toggles it). An input about one thing (a tab, a pane)
/// puts that thing's id in its own, so that two targets are two screens.
struct PaletteInput: Hashable {
    let id: String
    let pill: PalettePill
    /// The field's placeholder: what to type.
    let prompt: String
    let initialValue: String
    /// The completions of the text in the field, best first.
    let completions: @MainActor (String) -> [PaletteCompletion]
    /// Do the action with the text in the field, or refuse it. On `.done`
    /// the palette closes. An action that must run after the palette has
    /// closed and focus is back in the pane sets `AppState.postPaletteAction`.
    let commit: @MainActor (String) -> PaletteCommit

    init(
        id: String,
        pill: PalettePill,
        prompt: String,
        initialValue: String = "",
        completions: @escaping @MainActor (String) -> [PaletteCompletion] = { _ in [] },
        commit: @escaping @MainActor (String) -> PaletteCommit
    ) {
        self.id = id
        self.pill = pill
        self.prompt = prompt
        self.initialValue = initialValue
        self.completions = completions
        self.commit = commit
    }

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

/// A row under an input field: what it shows, and the text the field takes
/// when the row is picked. `subtitle` is a path when there is one: the row
/// cuts it in the middle, so that both ends stay.
struct PaletteCompletion: Equatable {
    let title: String
    let value: String
    let subtitle: String?

    init(title: String, value: String, subtitle: String? = nil) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
    }
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
    /// True until the screen has shown once: only then does the panel
    /// select the field's text, the initial value.
    var isFirstShow = true

    init(input: PaletteInput) {
        self.input = input
        text = input.initialValue
    }

    var placeholder: String { input.prompt }
    var initialQuery: String { text }

    func sections(for query: PaletteQuery, context _: PaletteContext) -> [PaletteSection] {
        text = query.raw
        if failure != nil, text != refusedText {
            failure = nil
            refusedText = nil
        }
        completions = input.completions(text)
        let items = completions.map {
            PaletteItem(id: Self.itemID($0), title: $0.title, subtitle: $0.subtitle, subtitleIsPath: true, action: {})
        }
        return items.isEmpty ? [] : [PaletteSection(header: nil, items: items)]
    }

    /// The text that `item`, a row of this screen, puts in the field.
    func completion(for item: PaletteItem) -> String? {
        completions.first { Self.itemID($0) == item.id }?.value
    }

    /// Commit `text`. True when the palette closes; false when the value
    /// was refused, and `failure` has the reason.
    func commit(_ text: String) -> Bool {
        switch input.commit(text) {
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
}
