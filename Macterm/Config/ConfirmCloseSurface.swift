/// The user's ghostty `confirm-close-surface`: `true` (the default) asks
/// before a close or a quit ends a running program, `false` never asks,
/// `always` asks at every close. Every close guard reads it through
/// `ForegroundPolicy.needsConfirmClose` and `AppState.judgeClose`.
///
/// libghostty applies the key in `ghostty_surface_needs_confirm_quit`, and a
/// read-only surface always asks there. Macterm judges a pane itself only
/// for `true`, because the surface cannot see a remote program.
///
/// The raw values are ghostty's enum tag names.
enum ConfirmCloseSurface: String {
    case `false`
    case `true`
    case always

    /// An enum key, so it arrives as a bare tag pointer (`.tag`).
    static let key = GhosttyConfigKey.tag("confirm-close-surface")

    /// An unset or unknown value means `true`, ghostty's default, so an
    /// unknown value never turns the warning off.
    static func resolve(configValue: String?) -> ConfirmCloseSurface {
        configValue.flatMap(ConfirmCloseSurface.init(rawValue:)) ?? .true
    }

    /// Whether the verdict depends on what runs in the pane, so that Macterm
    /// must judge a remote pane's state (and ask the host of a plain shell).
    /// For `false` and `always`, the surface's reading answers alone.
    var judgesPaneState: Bool {
        self == .true
    }
}
