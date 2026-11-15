import Foundation

/// The host targets that the app carries a server build for
/// (`Contents/Resources/server/macterm-<key>-<target>.gz`), as
/// `scripts/build-server.sh` names them.
enum ZmxHostTarget: String, CaseIterable, Equatable {
    case linuxX86_64 = "x86_64-linux"
    case linuxAarch64 = "aarch64-linux"
    case macOS = "universal-macos"

    /// The target from the host's `uname -s` and `uname -m`. Linux names the
    /// CPU as `x86_64` or `amd64`, and `aarch64` or `arm64`. A macOS host
    /// takes the universal build, whatever its CPU. Anything else (a BSD,
    /// a 32-bit or RISC-V Linux) has no build.
    static func detect(system: String, machine: String) -> ZmxHostTarget? {
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let machine = machine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch system {
        case "Darwin":
            return .macOS
        case "Linux":
            switch machine {
            case "x86_64",
                 "amd64": return .linuxX86_64
            case "aarch64",
                 "arm64": return .linuxAarch64
            default: return nil
            }
        default:
            return nil
        }
    }
}

/// When this app replaces the server that answers (design/002): the one
/// rule for the local server and for a host's server. `ProtocolFixtureTests`
/// pins it with the hello pairs of `server/schema/frames.json`.
///
/// - A lower level is older: replace it.
/// - A higher level is newer: never downgrade it.
/// - At the same level, builds have no order. Replace another build only
///   when the app owns the server's file (`ownsServer`), and never when the
///   app has no build key.
struct ServerReplacement: Equatable {
    /// The app's build key (`ServerBuilds.bundledKey`).
    var key: String?
    /// Locally: the server runs from the app's own file, or from a file that
    /// an update removed. On a host: this connect installed the app's build.
    var ownsServer: Bool
    var level: UInt32 = MactermProtocol.level

    func replaces(_ hello: MactermProtocol.Hello) -> Bool {
        if hello.level != level { return hello.level < level }
        guard let key, ownsServer else { return false }
        return hello.buildKey != key
    }
}
