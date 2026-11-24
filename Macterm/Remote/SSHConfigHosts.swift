import Darwin
import Foundation

/// A host of the user's ssh config: the name of a `Host` line, and the
/// `HostName` and `User` that ssh gives it.
struct SSHConfigHost: Equatable {
    let alias: String
    let hostName: String?
    let user: String?

    /// Where the alias goes, as a row's subtitle: `user@hostname`, the
    /// hostname, or `user@alias`. Nil when the config says neither.
    var detail: String? {
        switch (user, hostName) {
        case let (user?, hostName?): "\(user)@\(hostName)"
        case let (nil, hostName?): hostName == alias ? nil : hostName
        case let (user?, nil): "\(user)@\(alias)"
        case (nil, nil): nil
        }
    }
}

/// The hosts of the user's ssh config (`~/.ssh/config`), for the New Remote
/// Project screen (`RemoteHostsPaletteScope`). Each name of a `Host` line
/// that has no wildcard is a host, in the order of the file, one time each.
///
/// - `Include` is followed as ssh follows it: a relative path is under
///   `~/.ssh`, `~` is the home folder, a glob reads each match in order, and
///   the depth stops at 16. The lines of an included file before its first
///   `Host` line belong to the block of the `Include`.
/// - `HostName` and `User` are the first value of each key whose block
///   matches the alias (ssh's rule: the first value wins). A `Host` block
///   matches when one of its patterns matches the alias and no `!` pattern
///   does. A `Match` block is not read: its condition needs a connection.
/// - A file that is missing or not readable gives no hosts. Nothing is
///   cached: the screen reads the file again at each open.
enum SSHConfigHosts {
    /// ssh's own limit (`READCONF_MAX_DEPTH`).
    static let maxIncludeDepth = 16

    static func load(
        config: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config"),
        sshDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh"),
        home: String = NSHomeDirectory()
    ) -> [SSHConfigHost] {
        var reader = Reader(sshDirectory: sshDirectory, home: home)
        reader.read(config, condition: .always, depth: 0)
        return reader.aliases.map { alias in
            SSHConfigHost(
                alias: alias,
                hostName: reader.value("hostname", for: alias)?.replacingOccurrences(of: "%h", with: alias),
                user: reader.value("user", for: alias)
            )
        }
    }

    /// The keyword in lower case and the arguments of one line, nil for a
    /// blank line or a comment. `Key value`, `Key=value` and `Key = value`
    /// are the same; an argument in double quotes can have spaces. Pure.
    static func tokens(_ line: String) -> (key: String, args: [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let end = trimmed.firstIndex(where: { $0.isWhitespace || $0 == "=" }) else {
            return (trimmed.lowercased(), [])
        }
        let key = trimmed[..<end].lowercased()
        var rest = trimmed[end...].drop { $0.isWhitespace }
        if rest.first == "=" { rest = rest.dropFirst().drop { $0.isWhitespace } }
        var args: [String] = []
        var current = ""
        var quoted = false
        var hasToken = false
        for character in rest {
            if character == "\"" {
                quoted.toggle()
                hasToken = true
            } else if character.isWhitespace, !quoted {
                if hasToken { args.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { args.append(current) }
        return (key, args)
    }

    /// Whether `pattern` names one host: no `*` or `?`, and not a `!`
    /// negation.
    static func isLiteral(_ pattern: String) -> Bool {
        !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!")
    }

    /// The block that a line is in.
    enum Condition: Equatable {
        /// Before the first `Host` or `Match` line: every host.
        case always
        case host([String])
        /// A `Match` block, which is not read.
        case never

        func matches(_ alias: String) -> Bool {
            switch self {
            case .always: return true
            case .never: return false
            case let .host(patterns):
                var matched = false
                for pattern in patterns {
                    if pattern.hasPrefix("!") {
                        if fnmatch(String(pattern.dropFirst()), alias, 0) == 0 { return false }
                    } else if fnmatch(pattern, alias, 0) == 0 {
                        matched = true
                    }
                }
                return matched
            }
        }
    }

    private struct Entry {
        let condition: Condition
        let key: String
        let value: String
    }

    private struct Reader {
        let sshDirectory: URL
        let home: String
        var aliases: [String] = []
        var entries: [Entry] = []

        mutating func read(_ url: URL, condition start: Condition, depth: Int) {
            guard depth <= SSHConfigHosts.maxIncludeDepth,
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { return }
            var condition = start
            for line in text.split(whereSeparator: \.isNewline) {
                guard let (key, args) = SSHConfigHosts.tokens(String(line)) else { continue }
                switch key {
                case "host":
                    condition = .host(args)
                    for alias in args where SSHConfigHosts.isLiteral(alias) && !aliases.contains(alias) {
                        aliases.append(alias)
                    }
                case "match":
                    condition = .never
                case "include":
                    for path in args.flatMap(expand) {
                        read(URL(fileURLWithPath: path), condition: condition, depth: depth + 1)
                    }
                case "hostname",
                     "user":
                    if let value = args.first { entries.append(Entry(condition: condition, key: key, value: value)) }
                default:
                    break
                }
            }
        }

        func value(_ key: String, for alias: String) -> String? {
            entries.first { $0.key == key && $0.condition.matches(alias) }?.value
        }

        /// The files of one `Include` argument, in glob order.
        private func expand(_ argument: String) -> [String] {
            var path = argument
            if path == "~" || path.hasPrefix("~/") {
                path = home + path.dropFirst()
            } else if !path.hasPrefix("/") {
                path = sshDirectory.appendingPathComponent(path).path
            }
            var matches = glob_t()
            defer { globfree(&matches) }
            guard glob(path, 0, nil, &matches) == 0 else { return [] }
            return (0 ..< Int(matches.gl_pathc)).compactMap { index in
                matches.gl_pathv[index].map { String(cString: $0) }
            }
        }
    }
}
