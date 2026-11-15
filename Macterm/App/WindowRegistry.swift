import AppKit

/// The open terminal windows: each window's `WindowState`, which one is key,
/// and the `NSWindow` that each state belongs to (#345, #353). It holds no
/// model state. `AppState` decides what a window shows and calls in here to
/// add, remove and find windows, so this table survives the model cut-over
/// unchanged.
@MainActor @Observable
final class WindowRegistry {
    /// Every open terminal window's own state, in creation order.
    private(set) var windows: [WindowState] = []

    /// The window the user is in. Nil before the first window reports itself,
    /// and briefly while macOS has no key window (every window hidden).
    private(set) var keyWindowID: WindowState.ID?

    /// The canonical `WindowState` for each `NSWindow`, weakly keyed by the
    /// window. SwiftUI makes a view and its `@State` more than once for one
    /// real window, so the view cannot own the identity: the first state
    /// proposed for a window wins.
    ///
    /// Weak keys, not `ObjectIdentifier`s: an identifier is an address, and a
    /// closed window's address can be handed to the next window allocated,
    /// which would then find a dead window's state under its own key if the
    /// forget path had not run. A weak-keyed table drops the entry with the
    /// window.
    @ObservationIgnored
    private let statesByNSWindow = NSMapTable<NSWindow, WindowState>.weakToStrongObjects()

    var keyWindow: WindowState? {
        guard let keyWindowID else { return nil }
        return windows.first { $0.id == keyWindowID }
    }

    /// The key window, else the first one.
    var keyOrFirstWindow: WindowState? {
        keyWindow ?? windows.first
    }

    func contains(_ window: WindowState) -> Bool {
        windows.contains { $0.id == window.id }
    }

    func append(_ window: WindowState) {
        guard !contains(window) else { return }
        windows.append(window)
    }

    func remove(_ window: WindowState) {
        windows.removeAll { $0.id == window.id }
    }

    func setKeyWindowID(_ id: WindowState.ID?) {
        keyWindowID = id
    }

    /// The state of `nsWindow`, if one is recorded.
    func state(for nsWindow: NSWindow) -> WindowState? {
        statesByNSWindow.object(forKey: nsWindow)
    }

    /// Record `proposed` for `nsWindow` unless a state is recorded already.
    /// Returns the recorded state and whether it is the new one.
    func adopt(_ proposed: WindowState, for nsWindow: NSWindow) -> (state: WindowState, isNew: Bool) {
        if let existing = statesByNSWindow.object(forKey: nsWindow) { return (existing, false) }
        statesByNSWindow.setObject(proposed, forKey: nsWindow)
        return (proposed, true)
    }

    /// Drop the record of `nsWindow` and return its state.
    func forget(_ nsWindow: NSWindow) -> WindowState? {
        guard let state = statesByNSWindow.object(forKey: nsWindow) else { return nil }
        statesByNSWindow.removeObject(forKey: nsWindow)
        return state
    }

    func nsWindow(for window: WindowState) -> NSWindow? {
        for case let candidate as NSWindow in statesByNSWindow.keyEnumerator()
            where statesByNSWindow.object(forKey: candidate) === window
        {
            return candidate
        }
        return nil
    }
}
