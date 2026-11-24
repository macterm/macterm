# Views and windows

This file loads when you work in `Macterm/Views/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## Tab switcher previews (#344)

When you hold the Recent Tab chord, `TabSwitcherOverlay` shows one card for each tab in the cycle (`TabCycler.order`, limited by `Preferences.recentTabCandidates`). Each card is a mosaic of `PanePreview`s.

- The cards are **live**. `PanePreviewSampler` is the one owner of `GhosttyTerminalNSView.rendersForPreview`. A cycle begins its client (`.tabSwitcher`), and `syncOcclusion` then reports each offered pane as visible, so libghostty wakes its renderer. Macterm samples at 5 Hz until `TabCycler.finish` ends the client. Every exit from a cycle goes through it, so no renderer stays awake.
- `PanePreview.frameID` skips a new sample of a pane whose IOSurface did not change. Macterm draws the thumbnail through a provider that does not copy. This keeps a hold at about 7% CPU, in place of 30%.
- No card and no pane in a card is dimmed or outlined. The selected card has the selection fill behind its preview and a bold title.
- Hover never scrolls the rows (`HoverSelectionTracker`, shared with the palette).
- The cards draw a tab with `TabPreviewMosaic`, which the project screen's grid also uses.
- Do not bring back a foreground copy-poll or a renderer that uses text as a stand-in. We removed both when we could sample panes that are off screen.

## The project screen's grid

`EmptyProjectView` shows the project's name, path and keys on the left, and `ProjectScreenGrid` on the right: one card for each tab, then one card for each child project, in the order of the sidebar (`ProjectScreenGridLayout.cards`). A project with no tabs and no children shows no grid.

- **All cards have one size** (`ProjectScreenGridLayout.cardSize`): half the grid's width, at the aspect of the screen, which is the terminal area that each tab fills. Two columns, filled row by row. The second column starts half a card lower (Ethan's reference image).
- A tab's card is only the live preview of the tab (`TabPreviewMosaic`, fitted in the card). Its accessibility label is the tab's title. A child's card shows its name and its folder, with no path line for a project with no folder.
- A click on a tab's card shows the tab. A click on a child's card shows the child's project screen.
- **The previews are live only while the screen shows and its window is visible** (`WindowVisibilityReader`, the window's occlusion state). The grid is the client `.projectScreen(window id)` of `PanePreviewSampler`: `AppState.showProjectScreenPreviews` and `endProjectScreenPreviews`. `onDisappear`, the occlusion change and `AppState.forgetWindowState` end it.
- The hover is the tab switcher's selection fill (`RowHoverTracker`). No other state dims or outlines a card.

## Windows and sidebars, AppKit reach-throughs

- **Settings window**. `PinnedSidebar` locks the sidebar (it sets min and max thickness of the `NSSplitViewItem` to the same value, and `canCollapse = false`). A `DividerShield` over the divider also locks it. SwiftUI resets the column metrics on events that have no hook, so both layers are load-bearing. If you replace the delegate of the split view, the app crashes. The empty `NSToolbar` (`.unified`) gives the window its roomier titlebar. Never set `titlebarAppearsTransparent` on it: a transparent titlebar draws no scroll-edge band, and a scrolled pane runs under its title (`SettingsWindowChrome`).
- **The width of the sidebar of the main window** is persisted for each window (`WindowSnapshot.sidebarWidth`, default `Preferences.defaultSidebarWidth`).
  - `WindowAppearance.restoreSidebarWidth` restores it through `NSSplitView.setPosition`. It tries again across run-loop ticks until the split view exists. The autosave key of SwiftUI has a runtime address in it, which you can never read back, and `navigationSplitViewColumnWidth(ideal:)` is ignored.
  - `pinSidebarAutosaveName` gives the split view a stable name. `pruneChurnedAutosaveKeys` sweeps the old keys (it matches the marker `(unknown context at $`, and it is skipped under tests).
  - A sidebar that is collapsed is left alone. `forgetSidebarWidthRestore` clears the slot of a window that closed.
- **The frame of the main window** is persisted for each window too (`WindowSnapshot.frame`, the `frameDescriptor` string of AppKit). Macterm records it on every move and resize outside full screen. `WindowAppearance.restoreFrame` restores it through `setFrame(from:)` (#496).
  - The frame autosave of the `WindowGroup` of SwiftUI uses the content type of the scene as the key. That prints a private type (`AppColorScheme`) as `(unknown context at $ADDR)`. It therefore wrote a new `NSWindow Frame …` key at every launch and never read one back.
  - A stable name is not the fix. We measured it with `AppColorScheme` made internal: every window of the group writes the one key `AppWindow-1`. SwiftUI therefore keeps one frame for each group (the window that moved last), and the other windows that Macterm restores open at the default size. The key also still changes each time that the modifiers of the scene closure change.
  - `disownFrameAutosave` clears the autosave name of the window at attach (one owner). `pruneChurnedAutosaveKeys` sweeps both families of stale keys.
  - Macterm centers a restored frame on the main screen at its saved size when it has less than 60 pt on any screen. An example is the corner of a hidden workspace of a window manager.
- **Never leave persistent window state to an autosave of SwiftUI**. We measured every one of them (sidebar column, window frame). Each one uses a key with a runtime address, so it resets in silence at every launch and update. A stable key in `WindowSnapshot` is the rule.
- **The overlay sidebar peek is a side panel, the same as the Project Insights panel** (`SidebarOverlayPanel`). It has the same surface (`glassPanel`) and the same corner and inset (`GlassPanelMetrics.sidePanelCornerRadius` and `sidePanelInset`), and it starts below the toolbar. Its hover exit edge counts the inset (`SidebarOverlayMetrics.exitEdge`).

  - `Sidebar` (with `SidebarOverlay`, `SidebarPresentationState` and `SidebarFolderDrop`).

  - `PasswordBubble`.
  - `PaletteScreenshot`. This is Capture Palette. It takes the screen around the palette. `WindowState.paletteAnchor`, an invisible view under the palette, marks the place. `MactermExtension.screenshotRect` frames it. ScreenCaptureKit captures it. The glass of the palette shows what is behind it, and a render of a view cannot draw that. The capture needs Screen Recording, and it asks the first time. `PaletteResponder` answers its chord while the palette is up. If you run it in any other way, it opens the palette and captures the first screen.
  - `PaneScreenshot`. This is Capture Pane. It copies the focused pane to the clipboard as a PNG. It uses the rendered frame of the pane (`PanePreviewCapture`, the same frame as the tab switcher), not a screen capture. It fills the transparent cells with the background of the pane, so the image is opaque. Window opacity, blur and glass do not show, and nothing behind the window shows through. It needs no Screen Recording. The cursor stays as the frame drew it.
  - `ToolbarMenu`: the right-click menu of the toolbar. It is a local mouse monitor, because AppKit consumes a right-click in the titlebar before `NSView.menu`.
