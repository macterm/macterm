import Darwin
import Foundation
@testable import Macterm

/// Defaults suites that no other test sees, with names that repeat in each run.
///
/// The names are a count, not a UUID. `removePersistentDomain` does not delete
/// the plist file: cfprefsd writes the empty domain back to
/// `~/Library/Preferences`. A UUID name therefore leaves one new file for each
/// test in each run. A count reuses the same files, and the wipe when a suite
/// is made removes what the last run left in it.
///
/// Two test runs at the same time (two worktrees) must not wipe the suites of
/// each other. Each run holds a lock on a slot file for its life, and the slot
/// is part of the name.
enum IsolatedDefaults {
    private static let count = LockedBox(0)

    /// The first slot that no other running test process holds. The kernel
    /// releases the lock when the process ends. If no lock file opens, the
    /// process id is the slot: the names are then new in each run.
    private static let slot: Int = {
        let directory = FileManager.default.temporaryDirectory
        for slot in 0 ..< 64 {
            let path = directory.appendingPathComponent("macterm-tests-defaults-\(slot).lock").path
            let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return slot }
            close(descriptor)
        }
        return Int(getpid())
    }()

    /// The name of a new suite, wiped. Use it where the name is also a bundle
    /// identifier (Sparkle keeps its settings in the domain of the host bundle).
    static func makeSuiteName() -> String {
        var number = 0
        count.mutate {
            $0 += 1
            number = $0
        }
        let name = "\(appBundleID).tests.defaults.\(slot).\(number)"
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        return name
    }

    /// A new suite, wiped.
    static func make() -> UserDefaults {
        UserDefaults(suiteName: makeSuiteName())!
    }
}
