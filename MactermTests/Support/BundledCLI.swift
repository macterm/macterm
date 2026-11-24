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
    /// pseudo-terminal, as in a shell.
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
        let stderr = Pipe()
        process.standardError = stderr
        let out: Data
        if terminal {
            var primary: Int32 = -1
            var replica: Int32 = -1
            try #require(openpty(&primary, &replica, nil, nil, nil) == 0, "openpty failed")
            defer { close(primary) }
            // No output processing, so a line ends in "\n" as it does in a pipe.
            var attributes = termios()
            tcgetattr(replica, &attributes)
            attributes.c_oflag &= ~tcflag_t(OPOST)
            tcsetattr(replica, TCSANOW, &attributes)
            process.standardOutput = FileHandle(fileDescriptor: replica, closeOnDealloc: false)
            do {
                try process.run()
            } catch {
                close(replica)
                throw error
            }
            // The child holds its own copy. Once it exits, a read of the
            // primary side fails (EIO), which is the end of its output.
            close(replica)
            out = readToEnd(primary)
        } else {
            let stdout = Pipe()
            process.standardOutput = stdout
            try process.run()
            // Drain both pipes before waiting, or a full pipe deadlocks the child.
            out = stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
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
