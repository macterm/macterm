import Foundation
@testable import Macterm
import Testing

@MainActor
struct ServerTargetsTests {
    // MARK: - The host's target

    @Test(arguments: [
        ("Linux", "x86_64", ZmxHostTarget.linuxX86_64),
        ("Linux", "amd64", .linuxX86_64),
        ("Linux", "aarch64", .linuxAarch64),
        ("Linux", "arm64", .linuxAarch64),
        ("Linux", "ARM64", .linuxAarch64),
        ("Darwin", "arm64", .macOS),
        ("Darwin", "x86_64", .macOS),
    ])
    func a_known_host_maps_to_its_asset(system: String, machine: String, target: ZmxHostTarget) {
        #expect(ZmxHostTarget.detect(system: system + "\n", machine: machine + "\n") == target)
    }

    @Test(arguments: [
        ("Linux", "i686"), ("Linux", "riscv64"), ("Linux", "armv7l"), ("FreeBSD", "amd64"), ("OpenBSD", "amd64"),
        ("", "x86_64"), ("Linux", ""),
    ])
    func a_host_with_no_build_maps_to_nothing(system: String, machine: String) {
        #expect(ZmxHostTarget.detect(system: system, machine: machine) == nil)
    }

    // MARK: - The bundled build

    @Test
    func the_bundled_key_is_the_one_in_the_name_of_the_macos_build() {
        let names = ["macterm-0123abcd-universal-macos.gz", "macterm-0123abcd-x86_64-linux.gz", "README"]
        #expect(ServerBuilds.key(in: names) == "0123abcd")
        // None, two, or a name that is not one word: no key.
        #expect(ServerBuilds.key(in: ["macterm-0123abcd-x86_64-linux.gz"]) == nil)
        #expect(ServerBuilds.key(in: names + ["macterm-ffff-universal-macos.gz"]) == nil)
        #expect(ServerBuilds.key(in: ["macterm-a b-universal-macos.gz"]) == nil)
    }
}
