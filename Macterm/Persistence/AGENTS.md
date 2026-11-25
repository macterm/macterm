# Persistence

This file loads when you work in `Macterm/Persistence/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## Persistence

- **The server keeps the model** in `~/Library/Application Support/<display name>/model.json` (design/010 §2): the projects, their tabs and panes. The app keeps what only a window needs in `gui-state.json` next to it (`GUIStateStore`): the windows, the pinned records and the desktop widgets' records. A file that does not read, or that a newer build wrote, is never written over. The wrapper configs are next to them.
- **v1's files are read once and never written**: `projects.json` (`ProjectStore.readV1`) and `workspaces_v3.json` (`WorkspaceStore.load`). The import (`AppState.importV1Files`) converts them at the first launch whose model has no `imported_v1` (design/010 §8). A return to an earlier build finds them as they were. Debug builds use `Macterm Debug/`, and the Debug bundle is `Macterm Debug.app` (`PRODUCT_MODULE_NAME` stays `Macterm`). Write the space wherever you name the bundle by path.
- A `Pane` ID is its session ID, and a `SplitBranch` ID is stored too. The session name is stored exactly as given. The app gives the server each pane's live folder (`pane.set`, `AppState.persistState`), so a pane whose session is gone starts its new shell where the user was.
  - One pane is one session. A v1 tab from a build with `pane mirror` (now removed) can hold two panes on one session: the import keeps the first pane alone (`WorkspaceSerializer.withoutRepeatedSessions`), across the whole file: project workspaces first, then pinned tabs, the quick terminal and desktop widgets.
  - Only an explicit Apply Layout applies a declared layout (palette, menu, Settings row, `layout apply`), as `tab.layout` requests. When you select a project or start Macterm again, Macterm never reads it.
- **A directory is not an identity**. `ProjectStore.create` always appends a new project. `findOrCreate` exists only for callers that must be idempotent (the `open-project` hook of `BenchmarkControl`, and the folder rows of the palette).
- Project declarations are YAML in `~/.config/macterm/projects/`. All build flavors share them. They look at the `$HOME` env first, through `ProjectPath.currentHome`.
  - `name:` is for display only. When Settings → Projects makes a project from the file, each slash in it becomes a hyphen (`ProjectStore.allowedName`). `path:` is the identity (scp-style, with `~` when Macterm writes it). `tabs:` is optional.
  - The schema is `assets/project.schema.json`. Keep them in sync.
  - Only an explicit Save Layout and the editor of the user write a file. Only Settings → Projects → Layouts → Remove deletes it.
  - Matching is by the canonical `path:`. The slug of the name of the project breaks a tie when one directory backs several projects (`ProjectSlug.owns`). Macterm surfaces duplicates. It never deletes them.
- `save` records `run:` as the live foreground command (`ProcessInspector.runningCommand`, for a remote pane the command line of the host's foreground report). It records `shell:` only for a shell that is not the default. `apply` (`LayoutReconciler`) matches by the same `(run, cwd)`. Files that do not parse surface `LayoutFileError`. An empty `tabs:` is a bare declaration.
- `LayoutFile` has no form on disk. Do not add helpers to load or serialize it.
- **The tab of the quick terminal is the one tab of a hidden project** (`alias: quick`, design/010 §11), so the server keeps it as any tab.
  - `AppState` adopts `QuickTerminalService.shared.splitState` one time (`adoptQuickTerminal`, which you can inject at init for tests). The state is a view of that project, and `ensureTab` makes the project and its tab when they are not there. The panes connect only when the panel is shown for the first time, so until then they have zero clients.
  - Results: a quit kills nothing and confirms nothing while the session server is bundled. A close of a pane in the panel ends its session.
- Settings → Projects duplicates the alerts for layout and remove. Keep them gated on `AppState.DialogHost`, so that a confirmation that the palette raises does not also open Settings.
