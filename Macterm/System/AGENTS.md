# System helpers

This file loads when you work in `Macterm/System/`. The root `AGENTS.md` has the build, the architecture and the conventions.

- `Macterm/Persistence/`: `WorkspacePersistence` (snapshots, `WorkspaceStore`), `ProjectStore`, `FileStorage`, `ProjectFile` and `ProjectFileStore` (`~/.config/macterm/projects/`), `LayoutFileService`, `LayoutBuilder`, `LayoutSerializer` and `LayoutReconciler`, `LayoutFile` (only in memory), `PinnedLayoutStore`, `WidgetLayoutStore`, and `PasswordStore` (Keychain and `PasswordVault`).
- `Macterm/System/`
  - `ProcessInspector` (foreground pid → `runningCommand`, `runningShell` and `runningProcessName`).
  - `SessionClient` (the session paths of the panes, injectable), `ZmxRefreshGate`.
  - `SSHWrapper` (shared with the CLI target).
  - `ProcessLocale`, `FullDiskAccess`, `SecureInput`.
  - `NativeDesktopWidgets`: the frames of the system desktop widgets, from the window list.
  - `PasswordAuthenticator`.
  - `OnDeviceModel`: Apple's on-device model (FoundationModels), for Explain Output.
  - `ProcessRunner`: runs a short process to its exit and collects its output (Git reads, ssh commands).
  - `ObjCExceptionCatcher`: a trampoline with `@try` and `@catch`. AppKit raises ObjC exceptions that Swift cannot catch.
