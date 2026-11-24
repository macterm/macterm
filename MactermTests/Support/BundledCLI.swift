import Foundation
import Testing

/// The `macterm` binary the build copied into the test host's bundle
/// (`Contents/Resources/bin/macterm`), run as a child process. The CLI's own
/// code — argument parsing, help, the offline verbs — lives in the
/// `MactermCLI` target, out of reach of `@testable import`, so tests pin it by
/// running the real binary.
enum BundledCLI {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `macterm` with `arguments` until it exits. `environment`, when
    /// given, replaces the inherited one. With `terminal`, stdout is a
    /// pseudo-terminal, as in a shell, and its line ends read as "\n".
    static func run(
        _ arguments: [String],
        environment: [String: String]? = nil,
        terminal: Bool = false
    ) throws -> Result {
        let binary = try #require(
            Bundle.main.url(forResource: "macterm", withExtension: nil, subdirectory: "bin"),
            "bin/macterm missing from the built bundle"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdout = Pipe()
        let stderr = Pipe()
        var primary: Int32 = -1
        var replica: Int32 = -1
        if terminal {
            try #require(openpty(&primary, &replica, nil, nil, nil) == 0, "openpty failed")
            process.standardOutput = FileHandle(fileDescriptor: replica, closeOnDealloc: false)
        } else {
            process.standardOutput = stdout
        }
        process.standardError = stderr
        try process.run()
        let out: Data
        if terminal {
            // The child holds its own copy. Once it exits, a read of the
            // primary side fails (EIO), which is the end of its output.
            close(replica)
            out = readToEnd(primary)
            close(primary)
        } else {
            // Drain both pipes before waiting, or a full pipe deadlocks the child.
            out = stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var text = String(decoding: out, as: UTF8.self)
        if terminal { text = text.replacingOccurrences(of: "\r\n", with: "\n") }
        return Result(
            status: process.terminationStatus,
            stdout: text,
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    private static func readToEnd(_ descriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return data }
            data.append(buffer, count: count)
        }
    }
}
