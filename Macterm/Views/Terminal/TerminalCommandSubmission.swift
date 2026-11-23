import Foundation

/// When a key or a text reports a submission (`GhosttyTerminalNSView`
/// `onCommandSubmitted`, which project memory reads).
enum TerminalCommandSubmission {
    /// Hardware key codes (Carbon `kVK_*`) of Return and keypad Enter. They
    /// mirror `HotkeyRegistry`'s vocabulary, pinned to it by
    /// `TerminalCommandSubmissionTests.keyCodesMatchHotkeyRegistry`, because
    /// that registry is `@MainActor` and this helper is isolation-free.
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    static func isReturn(
        keyCode: UInt16,
        isRepeat: Bool,
        hasMarkedText: Bool,
        hasUserModifiers: Bool
    ) -> Bool {
        returnKeyCodes.contains(keyCode) && !isRepeat && !hasMarkedText && !hasUserModifiers
    }

    static func textContainsNewline(_ text: String) -> Bool {
        text.contains("\n") || text.contains("\r")
    }
}
