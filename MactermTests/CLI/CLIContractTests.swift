import Foundation
@testable import Macterm
import Testing

/// The v1 CLI contract as files (`server/src/cli/golden/`), checked against
/// the bundled `macterm`. The Zig port of the CLI (design 011) reads the same
/// files (`server/src/cli/contract.zig`).
///
/// - `golden/contract.json`: each command (its path, abstract, usage line,
///   subcommands, options and positional arguments), in a neutral form. The
///   test compares it with the command tree of the CLI, and compares the
///   `--help` of each command with it by structure: the overview, the usage
///   line, the set of options, arguments and subcommands, and each abstract.
/// - `golden/cases.input.json`: the inputs, written by hand. Each case is an
///   argument line, the canned response of the stand-in app for each wire
///   command, the protocol version of the stand-in app (`app_version`), and
///   the v2 `method` that the line maps to (null until its 011 issue sets it).
/// - `golden/cases.json`: for each input, the requests that the CLI sends and
///   what it prints.
/// - `golden/help/*.txt`: the raw `--help` text. For information only: no
///   test compares it.
///
/// The test host is a Debug build, so the contract includes the debug verbs
/// (`debug` is true). The port reads them as optional.
///
/// To write the files again after a change on purpose, run
/// `MACTERM_UPDATE_GOLDEN=1 mise run test` (`scripts/test.sh` passes the
/// variable to the test host) and review the diff. A missing file is written
/// and fails.
///
/// The suite is serialized: in update mode, one test writes `contract.json`
/// and the next reads it.
@Suite(.serialized)
struct CLIContractTests {
    private static let goldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CLI
        .deletingLastPathComponent() // MactermTests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("server/src/cli/golden")

    private static let updating = ProcessInfo.processInfo.environment["MACTERM_UPDATE_GOLDEN"] == "1"

    // MARK: - Contract and help

    /// ArgumentParser wraps help at `COLUMNS`, so the runs that print help pin it.
    private static let helpEnvironment = ["COLUMNS": "80", "HOME": "/var/empty"]

    @Test
    func the_command_tree_is_the_contract() throws {
        let (contract, help) = try Self.capture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try Self.compare(String(decoding: encoder.encode(contract), as: UTF8.self) + "\n", to: "contract.json")
        if Self.updating {
            try Self.writeHelp(help)
        }
    }

    @Test
    func every_command_prints_help_with_the_structure_of_the_contract() throws {
        let contract = try JSONDecoder().decode(
            CLIContract.self,
            from: Data(contentsOf: Self.goldenDirectory.appendingPathComponent("contract.json"))
        )
        let commands = Dictionary(uniqueKeysWithValues: contract.commands.map { ($0.path, $0) })
        // `help` is the help command that ArgumentParser adds: its `--help`
        // prints the help of the root.
        for command in contract.commands where command.usage != nil && command.path != ["help"] {
            let label = (["macterm"] + command.path).joined(separator: " ")
            let result = try BundledCLI.run(command.path + ["--help"], environment: Self.helpEnvironment)
            #expect(result.status == 0, "\(label) --help: \(result.stderr)")
            #expect(result.stderr.isEmpty)
            let help = HelpText(result.stdout)
            let children = command.subcommands.compactMap { commands[command.path + [$0]] }.filter { !$0.hidden }
            #expect(help.overview == command.overview, "\(label): overview")
            #expect(help.usage == command.usage, "\(label): usage")
            #expect(
                help.options == Dictionary(uniqueKeysWithValues: command.options.filter { !$0.hidden }.map { ($0.names, $0.helpText) }),
                "\(label): options"
            )
            #expect(
                help.arguments == Dictionary(uniqueKeysWithValues: command.arguments.filter { !$0.hidden }.map { ($0.name, $0.helpText) }),
                "\(label): arguments"
            )
            #expect(
                help.subcommands == Dictionary(uniqueKeysWithValues: children.map { ($0.path.last ?? "", HelpText.collapse($0.abstract)) }),
                "\(label): subcommands"
            )
            #expect(help.defaultSubcommand == command.default, "\(label): default subcommand")
        }
    }

    // MARK: - Requests and output

    @Test
    func every_argument_line_sends_and_prints_what_the_golden_file_says() throws {
        var recorded: [[String: Any]] = []
        for item in try Self.cases() {
            let socket = ContractSocket(responses: item.responses, version: item.appVersion)
            defer { socket.stop() }
            let result = try socket.cli(item.arguments)
            let normalize = { (text: String) in socket.normalize(text) }
            try recorded.append([
                "arguments": item.arguments,
                "exit": Int(result.status),
                "stdout": normalize(result.stdout),
                "stderr": normalize(result.stderr),
                "requests": socket.requests.map { try Self.json($0) },
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: recorded, options: [.prettyPrinted, .sortedKeys])
        try Self.compare(String(decoding: data, as: UTF8.self) + "\n", to: "cases.json")
    }

    /// One input line of `cases.input.json`.
    private struct Case {
        let arguments: [String]
        /// The response of the stand-in app to each wire command, as JSON text.
        let responses: [String: String]
        /// The protocol version that the stand-in app speaks.
        let appVersion: Int
    }

    private static func cases() throws -> [Case] {
        let data = try Data(contentsOf: goldenDirectory.appendingPathComponent("cases.input.json"))
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let known: Set = ["arguments", "method", "responses", "app_version"]
        for entry in entries {
            #expect(Set(entry.keys).isSubset(of: known), "cases.input.json: unknown key in \(entry["arguments"] ?? "?")")
            #expect(entry["app_version"] == nil || entry["app_version"] is Int, "cases.input.json: app_version is not a number")
        }
        return try entries.map { entry in
            let responses = try (entry["responses"] as? [String: Any] ?? [:]).mapValues { value in
                try String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            }
            return try Case(
                arguments: #require(entry["arguments"] as? [String]),
                responses: responses,
                appVersion: entry["app_version"] as? Int ?? ControlProtocol.version
            )
        }
    }

    // MARK: - Capture

    /// The contract of the bundled CLI, from its command tree and its help, and
    /// the raw help text of each command, keyed by its file name.
    private static func capture() throws -> (CLIContract, [String: String]) {
        let dump = try BundledCLI.run(["--experimental-dump-help"], environment: helpEnvironment)
        #expect(dump.status == 0, "\(dump.stderr)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(dump.stdout.utf8)) as? [String: Any])
        let root = (object["command"] as? [String: Any]) ?? object

        var commands: [CLIContract.Command] = []
        var rawHelp: [String: String] = [:]
        func walk(_ node: [String: Any], _ path: [String], debugParent: Bool) throws {
            let abstract = node["abstract"] as? String ?? ""
            let debug = debugParent || abstract.hasPrefix("[debug]")
            // `palette exec` is the raw runner of a palette `run:` action: it
            // reads its argv itself and has no help. Its case is in `cases`.
            var help: HelpText?
            if path != ["palette", "exec"] {
                let result = try BundledCLI.run(path + ["--help"], environment: helpEnvironment)
                #expect(result.status == 0, "macterm \(path.joined(separator: " ")) --help: \(result.stderr)")
                rawHelp[(path.isEmpty ? ["macterm"] : path).joined(separator: "-") + ".txt"] = result.stdout
                help = HelpText(result.stdout)
            }
            let children = node["subcommands"] as? [[String: Any]] ?? []
            let arguments = node["arguments"] as? [[String: Any]] ?? []
            commands.append(CLIContract.Command(
                path: path,
                abstract: abstract,
                discussion: node["discussion"] as? String,
                usage: help?.usage,
                // The parent's help does not list the added `help` command.
                hidden: node["shouldDisplay"] as? Bool == false || path == ["help"],
                debug: debug,
                subcommands: children.compactMap { $0["commandName"] as? String },
                default: help?.defaultSubcommand,
                options: arguments.filter { $0["kind"] as? String != "positional" }.map(Self.option),
                arguments: arguments.filter { $0["kind"] as? String == "positional" }.map(Self.argument)
            ))
            for child in children {
                if let name = child["commandName"] as? String { try walk(child, path + [name], debugParent: debug) }
            }
        }
        try walk(root, [], debugParent: false)
        return (CLIContract(commands: commands), rawHelp)
    }

    private static func option(_ entry: [String: Any]) -> CLIContract.Option {
        let names = (entry["names"] as? [[String: Any]] ?? []).compactMap { name -> String? in
            guard let text = name["name"] as? String else { return nil }
            return name["kind"] as? String == "short" || name["kind"] as? String == "longWithSingleDash" ? "-\(text)" : "--\(text)"
        }
        let abstract = entry["abstract"] as? String ?? ""
        return CLIContract.Option(
            names: names,
            value: entry["kind"] as? String == "option" ? entry["valueName"] as? String : nil,
            repeating: entry["isRepeating"] as? Bool ?? false,
            optional: entry["isOptional"] as? Bool ?? true,
            hidden: entry["shouldDisplay"] as? Bool == false,
            debug: abstract.hasPrefix("[debug]"),
            default: entry["defaultValue"] as? String,
            abstract: abstract
        )
    }

    private static func argument(_ entry: [String: Any]) -> CLIContract.Argument {
        let takes: String? = switch entry["parsingStrategy"] as? String {
        case "allRemainingInput": "all"
        case "allUnrecognized": "unrecognized"
        default: nil
        }
        return CLIContract.Argument(
            name: entry["valueName"] as? String ?? "",
            repeating: entry["isRepeating"] as? Bool ?? false,
            optional: entry["isOptional"] as? Bool ?? true,
            hidden: entry["shouldDisplay"] as? Bool == false,
            takes: takes,
            default: entry["defaultValue"] as? String,
            abstract: entry["abstract"] as? String ?? ""
        )
    }

    /// Writes the raw help files again, and removes the files of commands
    /// that are gone.
    private static func writeHelp(_ help: [String: String]) throws {
        let directory = goldenDirectory.appendingPathComponent("help")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where help[name] == nil {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        for (name, text) in help {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    private static func json(_ request: ControlRequest) throws -> Any {
        var copy = request
        copy.id = "-"
        let data = try JSONEncoder().encode(copy)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Compares `text` with the golden file. In update mode, or when the file
    /// is missing, it writes the file; a missing file also fails.
    private static func compare(_ text: String, to name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = goldenDirectory.appendingPathComponent(name)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if updating || existing == nil {
            try text.write(to: url, atomically: true, encoding: .utf8)
            if existing == nil {
                Issue.record("golden/\(name) was missing and is written now. Review it and commit it.", sourceLocation: sourceLocation)
            }
            return
        }
        #expect(
            text == existing,
            "The CLI no longer matches golden/\(name). For a change on purpose, run with MACTERM_UPDATE_GOLDEN=1 and review the diff.",
            sourceLocation: sourceLocation
        )
    }
}

/// `golden/contract.json`. The Zig reader is `server/src/cli/contract.zig`:
/// change both together.
struct CLIContract: Codable {
    struct Command: Codable {
        /// The words after `macterm`. The root is `[]`.
        var path: [String]
        var abstract: String
        var discussion: String?
        /// The usage line of the help, with its whitespace collapsed. Nil for a
        /// command that has no help.
        var usage: String?
        /// Not in the help of its parent.
        var hidden: Bool
        /// In Debug builds only.
        var debug: Bool
        var subcommands: [String]
        /// The subcommand that runs when the command is given alone.
        var `default`: String?
        var options: [Option]
        var arguments: [Argument]

        /// The overview of the help: the abstract, then the discussion.
        var overview: String {
            HelpText.collapse([abstract, discussion ?? ""].joined(separator: " "))
        }
    }

    /// A flag (no `value`) or an option.
    struct Option: Codable {
        /// With the dashes: `-h`, `--help`.
        var names: [String]
        var value: String?
        var repeating: Bool
        var optional: Bool
        var hidden: Bool
        var debug: Bool
        var `default`: String?
        var abstract: String

        var helpText: String {
            HelpText.collapse([abstract, `default`.map { "(default: \($0))" } ?? ""].joined(separator: " "))
        }
    }

    /// A positional argument.
    struct Argument: Codable {
        var name: String
        var repeating: Bool
        var optional: Bool
        var hidden: Bool
        /// `all`: every word that is left, flags too. `unrecognized`: every
        /// word that is not an option of the command. Nil: one word each.
        var takes: String?
        var `default`: String?
        var abstract: String

        var helpText: String {
            HelpText.collapse([abstract, `default`.map { "(default: \($0))" } ?? ""].joined(separator: " "))
        }
    }

    var commands: [Command]
}

/// The structure of a `--help` text, with the wrapping taken out: the
/// overview, the usage line, and the entries of the ARGUMENTS, OPTIONS and
/// SUBCOMMANDS sections with their descriptions.
struct HelpText {
    var overview = ""
    var usage = ""
    /// The names of each option (`["-h", "--help"]`) and its description.
    var options: [[String]: String] = [:]
    var arguments: [String: String] = [:]
    var subcommands: [String: String] = [:]
    var defaultSubcommand: String?

    init(_ text: String) {
        var sections: [String: [String]] = [:]
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "),
               line[..<colon].allSatisfy({ $0.isUppercase || $0 == " " }), !line[..<colon].isEmpty
            {
                current = String(line[..<colon])
                sections[current, default: []].append(String(line[line.index(after: colon)...]))
            } else {
                sections[current, default: []].append(line)
            }
        }
        overview = Self.collapse(sections["OVERVIEW"]?.joined(separator: " ") ?? "")
        usage = Self.collapse(sections["USAGE"]?.joined(separator: " ") ?? "")
        for (label, description) in Self.entries(sections["OPTIONS"] ?? [], label: #"-[^\s,]+(, -[^\s,]+)*( <[^>]+>)?( \.\.\.)?"#) {
            let names = label.components(separatedBy: ", ").compactMap { $0.split(separator: " ").first.map(String.init) }
            options[names] = description
        }
        for (label, description) in Self.entries(sections["ARGUMENTS"] ?? [], label: #"<[^>]+>( \.\.\.)?"#) {
            let name = label.split(separator: " ").first.map(String.init) ?? label
            arguments[name.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))] = description
        }
        for (label, description) in Self.entries(sections["SUBCOMMANDS"] ?? [], label: #"[a-z][a-z0-9-]*( \(default\))?"#) {
            let name = label.split(separator: " ").first.map(String.init) ?? label
            if label.hasSuffix(" (default)") { defaultSubcommand = name }
            subcommands[name] = description
        }
    }

    /// The entries of a section: a line indented by two spaces that starts with
    /// a match of `label` starts one, the rest of the line starts its
    /// description, and the lines with a deeper indent continue it. Other lines
    /// (a note such as "See 'macterm help …'") end the entry before them.
    private static func entries(_ lines: [String], label pattern: String) -> [(String, String)] {
        guard let regex = try? Regex(pattern) else { return [] }
        var result: [(String, [String])] = []
        var open = false
        for line in lines {
            if line.hasPrefix("  "), !line.hasPrefix("   ") {
                let body = line.dropFirst(2)
                if let match = body.prefixMatch(of: regex) {
                    result.append((String(body[match.range]), [String(body[match.range.upperBound...])]))
                    open = true
                } else {
                    open = false
                }
            } else if open, line.hasPrefix("   ") {
                result[result.count - 1].1.append(line)
            } else {
                open = false
            }
        }
        return result.map { ($0.0, collapse($0.1.joined(separator: " "))) }
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// A stand-in app: it records each request and answers a command with the
/// canned response for it, or with a bare ok.
private final class ContractSocket {
    let path = "/tmp/macterm-contract-\(UInt32.random(in: 0 ..< UInt32.max)).sock"
    private let home = "/tmp/macterm-contract-home-\(UInt32.random(in: 0 ..< UInt32.max))"
    private let server: ControlSocketServer
    private let received = LockedBox<[ControlRequest]>([])

    init(responses: [String: String], version: Int) {
        server = ControlSocketServer(socketPath: path)
        server.start()
        server.attach { [received, version] raw, _ in
            guard let request = try? ControlProtocol.decodeRequest(raw) else { return Data() }
            received.mutate { $0.append(request) }
            // The version probe of `--no-focus` is answered with a bare ok at the current version.
            let canned = responses[request.command] ?? #"{"ok":true}"#
            var object = (try? JSONSerialization.jsonObject(with: Data(canned.utf8))) as? [String: Any] ?? [:]
            object["v"] = version
            object["id"] = request.id
            var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            data.append(0x0A)
            return data
        }
    }

    var requests: [ControlRequest] { received.value }

    func stop() {
        server.stop()
    }

    func cli(_ arguments: [String]) throws -> BundledCLI.Result {
        try BundledCLI.run(arguments, environment: [
            ControlProtocol.socketEnvVar: path,
            "CFFIXED_USER_HOME": home,
            "HOME": home,
        ])
    }

    /// Replaces the paths of this run, which differ for each run.
    func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: path, with: "<socket>").replacingOccurrences(of: home, with: "<home>")
    }
}
