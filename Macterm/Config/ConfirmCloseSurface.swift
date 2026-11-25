import Foundation

/// The user's ghostty `confirm-close-surface`: when a close or a quit asks
/// first. Ghostty uses the one key for a pane close and for the quit prompt,
/// and so does Macterm: every close guard reads it through
/// `ForegroundPolicy.needsConfirmClose` and `AppState.judgeClose`.
///
/// - `true` (ghostty's default): ask when a program runs.
/// - `false`: never ask.
/// - `always`: ask at every close, also at an idle prompt.
///
/// libghostty applies the key itself in `ghostty_surface_needs_confirm_quit`
/// (the surface's reading), with one more rule: a read-only surface always
/// asks. Macterm judges the state of a pane itself only for `true`, where
/// the surface cannot see a remote program. For `false` and `always` the
/// surface's reading is the verdict, so the read-only rule of ghostty
/// stays.
///
/// The raw values are ghostty's own enum tag names
/// (`src/config/Config.zig`'s `ConfirmCloseSurface`), a wire contract with
/// libghostty.
enum ConfirmCloseSurface: String, CaseIterable {
    case `false`
    case `true`
    case always

    /// An enum key, so it arrives as a bare tag pointer (`.tag`).
    static let key = GhosttyConfigKey.tag("confirm-close-surface")

    /// An unset, unreadable or unknown value means `true`, ghostty's
    /// default, so an unknown value never turns the warning off.
    static func resolve(configValue: String?) -> ConfirmCloseSurface {
        guard let raw = configValue?.trimmingCharacters(in: .whitespaces) else { return .true }
        return ConfirmCloseSurface(rawValue: raw.lowercased()) ?? .true
    }

    /// Whether the verdict depends on what runs in the pane, so that Macterm
    /// must judge a remote pane's state (and ask the host of a plain shell).
    /// For `false` and `always`, the surface's reading answers alone.
    var judgesPaneState: Bool {
        self == .true
    }
}
