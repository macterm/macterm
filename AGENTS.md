# Macterm Codebase Guide

A macOS terminal emulator built with SwiftUI and libghostty. It has a project-based sidebar, split panes, persistent sessions, remote (ssh) projects, a quick-terminal overlay, desktop widgets and a control CLI. It has any number of windows on one shared model.

This file is the map: the build, the architecture, the folders and the conventions. Each area has its own `AGENTS.md` with the rules of that area, and it loads when you work in its folder (`CLAUDE.md` is a symlink to it in each folder). A rule has no backstory. The reason for a rule is in the doc comment on the symbol that the rule names and in the PR that introduced it. When you change a rule, change its doc comment too.

`scripts/check-agents.py` checks that each symbol and path in backticks in an `AGENTS.md` exists in the tree (CI job `Checks / Agents Map`). Run it after you rename or remove a symbol that a file names.

## Area files

| Folder | What its `AGENTS.md` covers |
| --- | --- |
| `Macterm/App/` | windows, hotkeys, tab names and activity, password prompts, pinned tabs, desktop widgets, first-run seed, color tags, Finder services and text files, Dock menu |
| `Macterm/Views/` | tab switcher previews, window frame and sidebar persistence, capture commands |
| `Macterm/Views/Terminal/` | surface rules, copy mode, Explain Output, read-only panes, animations |
| `Macterm/Memory/` | Project Insights |
| `Macterm/Search/` | the one search engine |
| `Macterm/Server/` | the local server client, local and remote panes as v2 sessions, remote projects, a host's server |
| `Macterm/System/` | system helpers, one ssh connection for each host |
| `Macterm/Protocol/` | the v2 protocol and its generated code |
| `Macterm/Control/` | the control CLI and its socket (`CLI/` links to it) |
| `Macterm/Intents/` | App Intents, Shortcuts, Spotlight |
| `Macterm/Palette/` | the palette, its screens, and extensions |
| `Macterm/Config/` | the ghostty config pipeline |
| `Macterm/Ghostty/` | the GhosttyKit header, bundled resources, adaptive background |
| `Macterm/Persistence/` | workspaces, projects, layouts |
| `Macterm/Settings/` | Settings panes |
| `IconRenderer/` | the adaptive icon and its helper |
| `server/` | the session server: build key, macOS attribution, the roaming link |
| `scripts/` | setup, e2e, older-macOS smoke, session benchmark |
| `scripts/record-demos/` | the demo clips of the website |
| `.github/` | CI, required checks, releases, the website |
| `MactermTests/` | unit test conventions |

## Build & Run

```bash
mise install          # Install tools (gh, swiftformat, swiftlint, xcodegen, xcbeautify)
mise run setup        # Download pre-built GhosttyKit.xcframework + ghostty resources + zmx
mise run run          # Build and launch (debug)
mise run logs         # Stream live logs from the debug app (--release for release app)
mise run format       # Auto-fix formatting with swiftformat
mise run lint         # swiftlint
mise run test         # Run the unit test suite
mise run e2e          # Debug build + end-to-end suite against the real app
mise run build        # Release build + DMG
mise run install      # Copy the built app to /Applications
```

`format`, `lint`, `test` and `e2e` show a spinner. They print output only when they fail. **Always pass `--verbose`** (`mise run test --verbose`) to stream the raw output.

**The Debug app signs ad-hoc, unless `Configs/Local.xcconfig` names an identity.** An ad-hoc designated requirement is the cdhash, and the cdhash changes at each build. TCC (Screen Recording, Accessibility, Full Disk Access, Local Network) therefore refuses each new `Macterm Debug.app`. Git ignores `Configs/Local.xcconfig`. A line `CODE_SIGN_IDENTITY = <name>` in it gives every Debug target a stable requirement. `Configs/Debug.xcconfig` includes it with `#include?`. `scripts/embed-zmx.sh` signs the bundled zmx with the same identity. The recipe for the self-signed certificate is in CONTRIBUTING.md ("Keeping macOS permissions across Debug builds").

- Keep `CODE_SIGN_IDENTITY` out of `settings.base` in `project.yml`. Project settings override the project xcconfig, so a value there hides the local identity. Release sets it in `settings.configs.Release`.
- A Release build takes its identity from `MACTERM_CODESIGN_IDENTITY` (`scripts/build.sh`, the release certificate in CI). The local file does not change it.
- The local identity must be a separate development certificate, never the release certificate. With it, every Debug build from any branch or worktree is the same app to TCC and gets the grants with no request.
- `codesign` reads the private key at each build. A headless build (an agent, `ssh`) cannot answer the keychain dialog, and a locked login keychain fails with `errSecInternalComponent`. A worktree with no `Configs/Local.xcconfig` signs ad-hoc. A file that names an identity that is not in the keychain stops the build at the start (`No certificate matching …`). It never falls back to ad-hoc, because a silent fallback removes the grants.

Macterm needs macOS 14 or later and Swift 6.0 or later. Liquid glass and some chrome refinements are macOS 26 (Tahoe) features. They are behind `#available` and `WindowAppearance.glassSupported`.

### The terminal core

- **"libghostty" here means `ghostty-internal`**. Upstream marks it "not for external use". `libghostty-vt` (the public library) has no surface API, so it is not a fallback. Treat every `ghostty_*` symbol as a symbol that can change without notice. Pin it, probe it and diff it. Do not assume it.
- `GhosttyKit.xcframework` and `Macterm/Resources/{ghostty,terminfo}` are artifacts of the `macterm/ghostty` fork. The bundled `zmx` is the build of `server/` at the same commit. Git ignores them. **Run `mise run setup` in every new checkout, including a git worktree**. Never make a symlink to them from another checkout. The presence check of setup would then never refresh them.
- The GhosttyKit release is **pinned** (`GHOSTTYKIT_TAG` in `scripts/setup.sh`). Setup records it in the stamp `.ghosttykit-tag`, which git ignores. A change of a pin is its own commit that a reviewer can check.
- The session server is `server/` in this tree (a fork of zmx v1.0.1). `server/AGENTS.md` has its build rules.
- If a tree looks stale (a stamp does not match reality), run `rm -rf GhosttyKit.xcframework Macterm/Resources/terminfo && mise run setup`.

## Architecture

```
MactermApp (SwiftUI @main)
  └─ WindowGroup                       one scene, N windows (#353)
       └─ MainWindow  ── WindowState   per window: project, tab per project, sidebar, sheets
            ├─ SidebarContent          List with native selection
            └─ WorkspaceView
                 └─ SplitTreeView      recursive
                      └─ TerminalPane
                           └─ TerminalSurface (NSViewRepresentable)
                                └─ GhosttyTerminalNSView   owned by PaneSurface, not SwiftUI
```

### Pane and PaneSurface

A `Pane` is the record of one terminal: its identity, its session, and the state that the session's output decides (titles, foreground, run state, bells). It holds no view. A `PaneSurface` is one host's view of it. `SurfaceRegistry.shared` owns every surface, keyed by its host and the pane id (`SurfaceHost`: `.window(id)`, `.incubator`, `.quickTerminal`, `.widget(id)`, design 010 §5), and it makes, finds and destroys the views. The surface owns the `GhosttyTerminalNSView`, its scroll view and the UI state of that view (search, copy mode, read-only, hover link, adaptive background, closing ghost). `TerminalSurface.makeNSView` returns `surface.ensureScrollView()`, a cached instance that lives as long as the surface. `dismantleNSView` does nothing. The view dies only through `PaneSurface.destroy()`, which `SurfaceRegistry.destroySurfaces(of:)` calls for every surface of a pane. A Ghostty surface is welded to its `NSView` and `CAMetalLayer`. If SwiftUI made the view again when the tree changes shape or you switch tabs, the surface would die. `SurfaceIncubator` is a window that is always invisible. It gives a pane that is off screen a window with a size, so that `createSurface()` can succeed early. A body asks `SurfaceRegistry.surface(for: pane, in: host)`; the host is `\.paneHost` (a window, the quick terminal or a widget sets it; the default `.incubator` gets the first surface). The first host takes the incubator's surface. That call makes the model object only: no view and no client exist before `ensureNSView`. Code with no host in hand (the CLI, intents, persistence) asks `SurfaceRegistry.view(of:)` or `preferredSurface(of:)`: the surface in the key window, else one in a visible window, else the first that has a view. `Pane` has no getter that passes through to a surface.

**The pane connects the callbacks of its view when it makes the view** (`Pane.connectViewCallbacks`, from `PaneSurface.ensureNSView`): execution tracking, titles, search, bells, notifications and project memory. A pane that no window drew (a `tab new --no-focus` tab, a background tab that a launch warmed) therefore records its submissions and output, and `pane list` follows its runs. `TerminalSurface.configure` sets only the callbacks that need the window that draws the pane: focus, splits, zoom, process exit, tab titles, links, the adaptive background, and `onRunEnded` (the acknowledgement of a run that the user looks at). The poll pauses while the app is inactive and no window is visible (`PollCadence`), so the output heartbeat can be the only signal of a run in such a pane.

### State

- **`AppState`** is the single `@Observable` root. It is passed with `.environment()`. You can inject `WorkspaceStore` for tests. The parts that are apart from the model are their own objects, so the model cut-over (design 010) does not touch them: `WindowRegistry` (the open windows, the key window, the `NSWindow` table), `TabCycler` (the Recent Tab cycle and the switcher's previews) and `LayoutFileService` (read and write the project layout files).
- **`ModelState`** holds the workspaces (`AppState.model`). The `ModelMirror` of design 010 replaces it as one unit. The project list joins it at the cut-over, when the `ProjectStore` writers go.
- **`ModelWriter`** (`Macterm/Model/Workspace.swift`) is the one writer of the tab model. `SplitBranch`, `TerminalTab` and `Workspace` are in the same file, and their setters and mutators are `fileprivate`, so the compiler refuses a change from any other file. Its verbs are the requests of design 010 §3 (`tabSet`, `paneSplit`, `splitRatio`). At the cut-over to the server's model, only their bodies change. Persistence stays the caller's: `AppState` saves after a change.
- **`ProjectStore`** is the project list (`projects.json`). It is saved on its own.
- **`Workspace`** is the collection of tabs of one workspace, `AppState.workspaces[id]`. Its `kind` is `project`, `pinned` or `scratch` (`WorkspaceKind`; `quick` and `widget` are for the cut-over, when those tabs join `workspaces`). A project's workspace has the project's id; the pinned and scratch tabs are sentinel workspaces with fixed ids (`PinnedTabs.workspaceID`, `ScratchTabs.workspaceID`, see Pinned Tabs).
- **`TerminalTab`** is a `SplitNode` tree plus the IDs of the focused pane and the zoomed pane. **`SplitNode`** is `.pane(Pane)` or `.split(SplitBranch)`. The tree operations of `SplitNode` are pure: they build new branches and keep each branch's `id`. Only a divider drag changes a branch in place (its ratio).
- **`WindowState`** (`Macterm/App/WindowState.swift`) exists once for each window. It holds the project that the window shows and its tab for each project (`activeTabIDs`). It also holds the width and visibility of the sidebar, and the flags of the palette and sheets. Macterm saves it as `WindowSnapshot`.
- **`Preferences`** is an observable wrapper for UserDefaults. Never touch `UserDefaults.standard` in app code. Under tests, `Preferences.defaults` resolves to a side suite that Macterm wipes.

## Layout

- `Macterm/App/`: `AppState` (with `AppState+…` extensions for pinned tabs, the first run, the quick terminal, desktop widgets, text files and the bell badge), `WindowState`, `WindowRegistry`, `TabCycler`, `Preferences`, `Hotkeys`, `KeyRouter`, `Responders`, `KeybindPassthrough`, `GlobalHotkeys`, `AppCommand` with `AppCommandActions` and `AppCommandMenu` (the one source of the actions that a user can invoke: the palette, the menus and Settings render from `AppCommand.allCases`), `FocusRestoration`, `Updater` (Sparkle), `FirstRunSeed`, `Tutorial`, `FinderServices`, `OpenFolder`, `TextFileDefaults`, `DockMenu`, `BellBadge`, `AdaptiveIcon…`, `PasswordPromptMonitor`, `BenchmarkControl`, `PollCadence`, `RecencyStack`.
- `Macterm/Views/`: `MainWindow`, `Sidebar…`, `SplitTreeView`, `AnimatedSplitView` with `SplitLayout`, `TerminalPane`, `TerminalSurface`, `PaneDragDrop`, `CommandPalette`, `TabSwitcherOverlay`, `QuickTerminal`, `DesktopWidgetWindows`, `SurfaceIncubator`, `QuitConfirmation`, `NewRemoteProjectSheet`, `Toast`, `PasswordBubble`, `WindowAppearance`. `Terminal/` has `GhosttyTerminalNSView`, `PaneSurface` with `SurfaceRegistry`, and what the pane view needs.
- `Macterm/Ghostty/`: `GhosttyApp` (init, config, tick), `GhosttyCallbacks`, `ThemeResolver`, `Theme` (all UI colors), `AdaptiveTerminalBackground`, `AdaptiveTerminalChrome`.
- `Macterm/Model/`: `ModelState`, `SplitNode`, `Pane`, `Workspace` (with `WorkspaceKind`), `TerminalTab`, `Project`, `ProjectPath`, `PinnedTabs`, `DesktopWidget`, `ForegroundSample`, `TerminalExecutionTracker`, `CopyMode`, `OutputExplanation`, `PasswordPrompt`, `FileLink`, `TextFileEditor`.
- `Macterm/Memory/`: Project Insights.
- `Macterm/Persistence/`: `WorkspacePersistence`, `ProjectStore`, `LayoutFileService`, `ProjectFileStore`, the layout files, `PinnedLayoutStore`, `WidgetLayoutStore`, `PasswordStore`.
- `Macterm/System/`: `ProcessInspector`, `SSHConnections`, `SSHWrapper`, `OnDeviceModel`, `ProcessRunner` and other wrappers of system services.
- `Macterm/Config/`: `MactermConfig`, `MactermConfigFile`, `GhosttyConfigSource` and the readers of single ghostty keys.
- `Macterm/Settings/`: the Settings panes.
- `Macterm/Server/`: the client of the local server and of a host's server.
- `Macterm/Protocol/`: the v2 protocol (`MessagePack`, `ProtocolFrame`, the generated `MactermProtocol`).
- `Macterm/Link/`: the packet layer of the roaming link.
- `Macterm/Control/`: the control socket, its handler and the agent skills.
- `Macterm/Intents/`: App Intents.
- `Macterm/Palette/`: the palette engine, its screens (`Scopes/`) and extensions (`Custom/`).
- `Macterm/Search/`: the search engine.
- `IconRenderer/`: `macterm-icon-renderer`, the adaptive icon's helper.
- `CLI/`: the `macterm` binary (ArgumentParser).
- `server/`: the session server (Zig), and the host scripts in `server/host/`.
- `extensions/`: the extensions that users install from Settings.
- `scripts/`: setup, build, release, the e2e suite and the benchmarks.
- The user docs are in the `macterm/website` repository. `.github/AGENTS.md` says how a feature and its docs PR go together.

## Tests

- Unit tests are in `MactermTests/`, one `XxxTests.swift` for each production type (see `MactermTests/AGENTS.md`).
- The e2e suite is `scripts/e2e/`, the release smoke is `scripts/older-macos-smoke.sh`, and the session benchmark is `scripts/session_bench.py` (see `scripts/AGENTS.md`). CI runs them; `.github/AGENTS.md` has the checks.
- The server tests are `server/test/*.bats` and the Zig tests (see `server/AGENTS.md`).

## Conventions

### Writing style

- **Write all text that you generate in ASD-STE100 style** (Simplified Technical English). This includes documentation, the website, README and CONTRIBUTING, Settings text, CLI output, error messages, code comments, commit messages and PR descriptions.
- Use the `asd-ste100` skill (https://github.com/danyuchn/asd-ste100-skill, MIT, kept in `.claude/skills/asd-ste100/`). Run its linter on the Markdown that you write: `python3 .claude/skills/asd-ste100/scripts/ste-lint.py <file>`.
- Use **Strict** mode for procedures, error messages, CLI output, Settings captions and agent skills. Use **STE-flavored** mode for README, docs prose and PR text.
- Follow `WRITING.md` for Macterm terms and the words to use. It is the project glossary.
- The skill has no copy of the official dictionary of ASD. It checks sentence structure, not approved words. Do not claim that text complies with the dictionary.
- Keep every fact, condition and hedge. Do not change a product term, a command, a key name, a file path or a code identifier to make a sentence simpler.

### Localization

The GUI text is in three String Catalogs: `Macterm/Localizable.xcstrings` (the app), `Macterm/InfoPlist.xcstrings` (the permission prompts of `Info.plist`) and `Macterm/ServicesMenu.xcstrings` (the Finder → Services item, keyed by its title after the build puts the display name in, so it has one entry for each build). The source language is English. The translations are Korean (`ko`) and Simplified Chinese (`zh-Hans`). `TRANSLATING.md` is the guide for translators, with the word table for each language.

- **Write a `String` that the GUI shows as `String(localized: "…")` where the code defines it.** A SwiftUI literal (`Text("…")`, `Button("…")`) is localizable as it is. `Text(someString)` is not: it shows the `String` verbatim. Write a whole sentence in one string, with interpolations. Never join localized fragments into a sentence. Add `comment:` to a short string whose meaning is not clear.
- **A catalog keys an entry by its text, not by its comment.** One English word with two meanings ("Show" as a heading and as a button) is one entry with one translation. Give the second meaning a semantic key with the English as its value: `String(localized: "toolbar.tabSwitcher.show", defaultValue: "Show", comment: …)`. `mise run strings` prints a notice for a key with two different comments.
- **Use `Text(verbatim:)` for text that is not language**: a path, a config key, a number, a symbol.
- **Never compare, persist or parse a localized string.** Split the value: an English or raw value for the logic, and a localized display property. `HotkeyRegistry.isUnbound` replaced a comparison of `displayString` against "None". A raw value is an identifier. `AppCommand.Category.title` is its label.
- **These stay English**: the CLI and the control socket, agent skills, logs, `macterm tutor`, the first-run seed, the YAML validator errors (`macterm palette list` prints them), ghostty config text, and text that Macterm types into a pane or matches against its output.
- **Never send `error.localizedDescription` to the CLI or a log.** The bundle has translations, so Foundation localizes its own errors (Cocoa, POSIX, `DecodingError`). Use `EnglishErrorText.describe(error)`. Our own error with a localized message adopts `EnglishDescribedError` (`LayoutFileError`, `CustomPaletteError`): it defines each message one time as a `LocalizedStringResource`, and resolves it with `String(localized:)` for the GUI and `String(english:)` for the CLI. `BilingualMessage` carries a message in both forms where one value goes to an alert and to the log.
- **The palette and Keymaps also match a command by its English title** (`AppCommand.searchAliases`, through `PaletteItem.searchAliases`), so `split` finds the row in every language. The English titles are resolved one time.
- **xcodebuild does not update the catalog**. `mise run strings` (`scripts/strings.sh`) builds Debug, merges the `.stringsdata` of the compiler into the catalog with `xcstringstool sync`, and removes unused entries. It writes the exact format of Xcode, so a build in the IDE does not rewrite the file. It reads only the `arm64` `.stringsdata` whose source file exists, because xcodebuild keeps the output of a removed Swift file and CI restores DerivedData from older builds. CI runs `mise run strings --check --no-build` after the unit tests.
- `LocalizationTests` requires a translation of every entry in every language of a catalog, with the placeholders of the English string. The test scheme runs in English (`language: en` in `project.yml`), because tests pin English text.
- **Settings → General → Language** (`Preferences.appLanguage`) lists **System** and each translation (`AppLanguage.available`), each in its own name. It is Foundation's `AppleLanguages` key in Macterm's own domain, which **System Settings → General → Language & Region → Applications** also writes, so the two places always agree. Read it from the persistent domain only: the global domain also has `AppleLanguages` (the list of macOS). Foundation reads the key at launch, so a change applies at the next start.

### Code style

- SwiftFormat and SwiftLint are enforced. Run `mise run format`, `lint` and `test` before you commit. swiftformat owns trailing commas. Never write `static weak var` (the two tools fight).
- Use `@MainActor @Observable` on all state classes. Do not use `@Published` or `ObservableObject`. Inject through `@Environment(AppState.self)`.
- Use `os.Logger` only, with one `private let logger = Logger(subsystem: appBundleID, category: "TypeName")` for each file. **Every interpolation is `.public`**. View the logs with `mise run logs`.

### Commits and PRs

- **Never add a `Co-Authored-By: Claude` trailer or any AI sign-off.**
- Subject lines say why. Split independent changes into separate commits.
- **PRs merge by squash only**. The PR title is the squash subject. If there is a conflict, merge `main` into the branch. Never rebase.
- Edit `AGENTS.md`. `CLAUDE.md` is a symlink to it in each folder. Put a rule in the `AGENTS.md` of the folder that it is about, and keep this root file under 300 lines. Merge `main` often when you change these files.

### UI principles

- **The GUI never shows the concept of unloading.** Macterm starts the shells of a project when a window selects it, so the user never loads or unloads a project. There is no action that stops a whole project and keeps its layout: no Unload command, menu item or Settings badge. Remove ends the sessions of a project for good. The CLI keeps the `loaded` field of `project list` (`not loaded` means that no workspace exists yet), because scripts read it.
- **A pane dims only when it is an unfocused split** (ghostty `unfocused-split-opacity` and `unfocused-split-fill`). No other state dims a pane: not a mirror, not a lost remote pane, not a card of the tab switcher. A dimmed sidebar row is a different thing and can stay.
- **Use native SwiftUI and AppKit components only**. Accept a native limitation. Do not mimic the behavior.
- All colors come from `MactermTheme`. Fixed system colors are allowed only for identity labels (`ProjectColor`, `AgentIcon.brandColor`).
- Put APIs that exist only on Tahoe behind `#available(macOS 26.0, *)`. For controls, also use `WindowAppearance.glassSupported`.
- Settings text: section headers are Title Case. Controls are in sentence case. Buttons are Title Case. `AppCommand` titles are Title Case.
- Settings captions are of two kinds, as in System Settings:
  - A **description** explains one control. It is the second `Text` of the control's label (`Toggle(isOn:) { Text("Title"); Text("…").settingsDescription() }`), which a grouped form draws under the title, with no divider. `settingsDescription()` sets the color, so the text dims with a disabled control, and a 2 pt top gap (`SettingsDescription.gap`). A row with no native subtitle (a slider, a custom `HStack` row) puts the text in a `VStack` with `.settingsSecondaryText()`, with the same gap added to the stack spacing.
  - A **footnote** is about the whole section. It is a row of its own, the last row of the section (`.settingsSecondaryText()`, which a status line in a pane also uses).
- **Controls on a row that a hover reveals change values, not the structure of the view. Never use `.onHover`.**
  - The new-tab button of `SidebarProjectHeader` is one `isRevealed` Bool. It drives padding, opacity and hit testing. An `if/else` in the label of a `List` row tears the row down and corrupts the reuse of `NSTableView`.
  - Hover comes from an `NSTrackingArea` (`RowHoverTracker`, `.activeInActiveApp`).
- With stacked `.dropDestination`s, only the first one that you apply wins.
- The closure of `.contextMenu(forSelectionType:)` in the sidebar runs one time for each open of the menu. It never runs on a redraw of a row. A cheap read such as `GitWorktrees.list` therefore belongs there. Inside it, `.disabled` on a `Menu` is dropped. The item then renders enabled over an empty submenu. A disabled submenu must therefore be a disabled `Button` (`SidebarContent.worktreesMenu`).
- **Anything that takes mouse input over a pane needs an AppKit view**. `GhosttyTerminalNSView` wins the hit test. SwiftUI gestures over a pane therefore never see the press. `PaneDragSource` and `ResizeDragBand` are `NSViewRepresentable`s. They forward what they do not own to `viewBeneath`. `NSHostingView` swallows hit tests even with `allowsHitTesting(false)`. Override `hitTest`.

### Adding a new feature

**A feature request starts with the question "does ghostty already do this?" The answer goes to the user before you write any code**. The config surface of libghostty is large. An implementation in Macterm of something that a ghostty key already expresses is a second answer. It disagrees with the first, and the user must find it. #393 deleted the scroll-speed slider and the whole wheel path of Macterm after someone tried `mouse-scroll-multiplier`. It also deleted two Settings controls that `tab-inherit-working-directory` and `macos-shortcuts` had answered all along. Read the config reference of ghostty and `ghostty.h` first. Then choose one of these:

- **A ghostty key covers it**. Read the key live from the loaded config (see `Macterm/Config/AGENTS.md`) and add **no Settings UI**. Where the default of Macterm must be different from the default of ghostty, that departure is a line in `MactermConfig.defaultsBody`. It is never a fallback in `Preferences`. Naming the key can be the whole answer. Say so, and do not build.
- **Ghostty can express it as a custom shader or a fork patch**. Prefer that to a reimplementation in Swift. Land it in Settings → Animations first, off by default.
- **It is a concept of Macterm itself** (projects, tabs for each project, the sidebar, layouts, windows, the CLI, sessions). Build it here and follow *Adding a new setting*.

A feature that changes what a user reads in the docs also gets a docs PR in `macterm/website`, filed with the feature PR (see `.github/AGENTS.md`).
### Adding a new action

1. Add an `AppCommand` case (a title in Title Case, a category, and a linked `HotkeyAction` if you can rebind it). The palette, the menus and Settings use it.
2. If you can bind it, add the `HotkeyAction` to `Hotkeys.swift` with its default, **and the matching `MactermKeybind` case and label**. The picker of App Intents repeats them, and `MactermIntentsTests` fails until they match.
3. Handle it in the right `KeyResponder` in `Responders.swift`.
4. Add a `HotkeysTests` case for new behavior of parsing or display.

### Adding a new setting

Macterm-side settings go through `Preferences`. Settings that have the shape of ghostty (theme, font, palette) belong in the ghostty config of the user. Do not add UI for them.

1. Add a `Preferences` property with a `didSet` that writes UserDefaults.
2. Only if libghostty must be forced: add `notifyConfigChanged()` in `didSet` and a line in `MactermConfig.regenerate()`.
3. Add UI to the matching pane in `Macterm/Settings/`. A new pane also needs a `SettingsPane` case and a line in `SettingsView.detail`.
## Known Limitations

- **Local sessions do not keep running after a restart of the Mac. Remote sessions do**. Every pane (workspace, pinned, quick terminal) persists as a session of the local server. It connects again after a quit.
- **Remote sessions need Macterm's server on the host**. Macterm installs it at the first connection, after one consent, for Linux x86_64 and aarch64 and for macOS. Any other host, and a host where the user declined, gets plain ssh shells that end with the connection. **Windows hosts are not supported.** When the attach command ends with no line of the script and not with 255, the app runs one probe (`HostCheck.windowsProbe`, `echo %OS% $env:OS`: `Windows_NT` in cmd.exe and PowerShell). If it answers, the connect fails with `Failure.windowsHost`, the log says so, and the pane shows its `Connection lost` badge. That failure gets no plain shells, because the plain-shell command is POSIX. The probe never reads the host's error text, which is in the host's language.
- **A remote session whose pane closed while no connection was up stays on the host.** Nothing reaps remote sessions.
- **A second window on the same tab draws the same panes**. Its surface is blurred where the pty has the size of the other view.
- **Adaptive background inference depends on the private renderer layout of ghostty** (BGRA8 IOSurface). It fails closed. Selections that a program renders (helix, or vim under mouse capture) remain a gap that we have not closed.
- **Developer ID does not sign Macterm**. On first launch, you need `xattr -cr /Applications/Macterm.app`, or Homebrew. The stable self-signed certificate keeps TCC grants across updates.
- **`macos-hidden = always` costs the menu bar**. Settings, Quit, About and Check for Updates have no route while it is on. Set the own preferences of Macterm before you switch it on.
- **Pane IDs are not stable across restarts.**
- **Desktop widgets are not in the widget gallery of the system**. See `Macterm/App/AGENTS.md`. They also do not take the monochrome look of the system while an app is in front.
- **Macterm detects password prompts only where it can read the tty that prompts**. This means local panes, and remote panes whose host session reports its tty (`tty_mode`, protocol level 3). It does not see anything behind an `ssh` that you typed by hand. It does not see prompts in raw mode that draw their own `*` mask either.
