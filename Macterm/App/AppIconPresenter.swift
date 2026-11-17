import AppKit

/// The one place the app icon is written. `AdaptiveIconController` decides
/// what the Dock shows — the bundled icon or the adaptive icon — and this
/// installs it.
///
/// `NSApp.applicationIconImage` changes the Dock tile and the app switcher,
/// never the bundle's icon in Finder. Assigning nil restores the bundle icon.
@MainActor
enum AppIconPresenter {
    /// Whether the adaptive icon is installed. Lets a refresh that keeps the
    /// bundled icon skip the AppKit write.
    private static var adaptiveInstalled = false

    static func applyBundled() {
        guard adaptiveInstalled else { return }
        NSApp.applicationIconImage = nil
        adaptiveInstalled = false
    }

    /// The bundled icon repainted in the theme (`AdaptiveIconController`).
    static func applyAdaptive(_ image: NSImage) {
        NSApp.applicationIconImage = image
        adaptiveInstalled = true
    }
}
