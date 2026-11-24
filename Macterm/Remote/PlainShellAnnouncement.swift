import Foundation

/// The pid of a plain shell on its host (0494). `server/host/plain.sh`
/// writes it as its first output, before it execs the login shell, in an
/// OSC that no terminal knows: `ESC ] 7701 ; shell=<pid> BEL`. `PlainShell`
/// removes it from the bytes before the surface gets them, so the pane
/// shows nothing of it. The pid is what the close check asks the host about
/// (`HostCommands.shellStateCommand`).
///
/// Only the first OSC 7701 in the first `limit` bytes counts. After that,
/// every byte goes to the surface as it is (libghostty ignores the OSC), so
/// a program in the shell cannot change the pid.
struct PlainShellAnnouncement {
    static let marker = Data("\u{1B}]7701;shell=".utf8)
    static let terminator: UInt8 = 0x07
    /// The bytes that may come before the announcement and in it.
    static let limit = 4096
    /// A pid has at most 10 digits.
    static let maximumDigits = 10

    /// The host's pid of the shell, when the announcement came.
    private(set) var pid: Int32?
    /// No announcement can come now.
    private(set) var isSettled = false
    /// The bytes held back: the start of what can be the announcement.
    private var held = Data()
    private var seen = 0

    /// The bytes of `chunk` that go to the surface, without the
    /// announcement. A start of the marker at the end of a chunk is held
    /// until the next chunk.
    mutating func consume(_ chunk: Data) -> Data {
        guard !isSettled else { return chunk }
        seen += chunk.count
        var data = held + chunk
        held = Data()
        if let start = data.range(of: Self.marker)?.lowerBound {
            let digitsStart = start + Self.marker.count
            if let end = data[digitsStart...].firstIndex(of: Self.terminator) {
                let digits = data[digitsStart ..< end]
                if let pid = Self.pid(digits) { self.pid = pid }
                isSettled = true
                data.removeSubrange(start ... end)
                return data
            }
            if data.count - digitsStart <= Self.maximumDigits, seen < Self.limit {
                held = Data(data[start...])
                return Data(data[..<start])
            }
            isSettled = true
            return data
        }
        if seen >= Self.limit {
            isSettled = true
            return data
        }
        // Hold a tail that is the start of the marker.
        let longest = min(Self.marker.count - 1, data.count)
        for count in stride(from: longest, to: 0, by: -1) where data.suffix(count) == Self.marker.prefix(count) {
            held = Data(data.suffix(count))
            return Data(data.dropLast(count))
        }
        return data
    }

    private static func pid(_ digits: Data) -> Int32? {
        guard !digits.isEmpty, digits.count <= maximumDigits, digits.allSatisfy({ (0x30 ... 0x39).contains($0) }) else { return nil }
        guard let value = Int32(String(decoding: digits, as: UTF8.self)), value > 1 else { return nil }
        return value
    }
}
