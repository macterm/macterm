import Foundation
@testable import Macterm
import Testing

/// Frames that the Zig side encoded (`server/schema/frames.json`, written by
/// `writeFixtures` in `server/tools/schema.zig`). The Swift side
/// must decode each one to the values that the Zig code put in, and encode
/// it again to the same bytes.
struct ProtocolFixtureTests {
    private struct Fixture: Decodable {
        let name: String
        let frame: String
        let reencodes: Bool
        let replace: Replace?
    }

    /// The answer of the replace rule for a server's hello (`Replace` in
    /// `schema.zig`).
    private struct Replace: Decodable {
        let key: String?
        let owns: Bool
        let replaces: Bool
    }

    private static func loadFixtures() throws -> [String: (bytes: Data, reencodes: Bool)] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Protocol
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("server/schema/frames.json")
        let list = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, (bytes(hex: $0.frame), $0.reencodes)) })
    }

    /// Empty if the file does not read: `every_fixture_is_here` then fails
    /// with the error.
    private static let fixtures = (try? loadFixtures()) ?? [:]

    private static func bytes(hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    /// The fixture's frame on channel 0, decoded.
    private static func control(_ name: String) throws -> ProtocolControl {
        let bytes = try #require(fixtures[name]?.bytes, "no fixture \(name)")
        let parsed = try #require(try ProtocolFrame.parse(bytes))
        #expect(parsed.length == bytes.count)
        #expect(parsed.frame.channel == ProtocolFrame.controlChannel)
        #expect(parsed.frame.kind == .msg)
        return try ProtocolControl.decode(parsed.frame.body)
    }

    @Test
    func every_fixture_is_here() throws {
        #expect(try Set(Self.loadFixtures().keys) == [
            "hello", "refuse",
            "channel.open request", "channel.open result",
            "channel.close request", "channel.close result",
            "error", "events", "later hello", "pane bytes",
            "attach", "exit", "claim",
            "state.subscribe result", "tab.create request", "model events", "model.import request",
            "replace: a lower level", "replace: a higher level",
            "replace: another build of the app", "replace: another build of another app",
            "replace: the same build", "replace: a build with no key", "replace: an app with no key",
        ])
    }

    @Test
    func every_fixture_encodes_again_to_the_bytes_of_the_Zig_side() throws {
        for (name, fixture) in Self.fixtures where fixture.reencodes {
            let parsed = try #require(try ProtocolFrame.parse(fixture.bytes))
            var frame = parsed.frame
            if frame.kind == .msg, frame.channel == ProtocolFrame.controlChannel {
                frame.body = try #require(ProtocolControl.decode(frame.body).encoded(), "\(name)")
            } else if frame.kind == .msg {
                frame.body = try MessagePackWriter.encode(Self.paneMessage(frame.body))
            }
            #expect(try frame.encoded() == fixture.bytes, "\(name)")
        }
    }

    @Test
    func the_handshake_decodes() throws {
        let hello = MactermProtocol.Hello(
            level: 1,
            minLevel: 1,
            build: "2.0.0-tip.1",
            role: .gui,
            epoch: 0x1234_5678_9ABC_DEF0,
            caps: ["tcc", "password-tty"],
            buildKey: "0123456789abcdef"
        )
        #expect(try Self.control("hello") == .hello(hello))
        #expect(try Self.control("refuse") == .refuse(.init(reason: "level_too_low", needsLevel: 4)))
    }

    /// Each server hello with a `replace` answer, through the one rule.
    @Test
    func the_replace_rule_gives_the_answer_of_each_hello_pair() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("server/schema/frames.json")
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)).filter { $0.replace != nil }
        #expect(cases.count == 7)
        for fixture in cases {
            let replace = try #require(fixture.replace)
            guard case let .hello(hello) = try Self.control(fixture.name) else {
                Issue.record("\(fixture.name): not a hello")
                continue
            }
            let rule = ServerReplacement(key: replace.key, ownsServer: replace.owns)
            #expect(rule.replaces(hello) == replace.replaces, "\(fixture.name)")
        }
    }

    @Test
    func requests_and_results_decode_as_their_methods() throws {
        guard case let .request(open) = try Self.control("channel.open request") else {
            Issue.record("not a request")
            return
        }
        #expect(open.id == 7)
        #expect(open.m == MactermProtocol.ChannelOpen.name)
        #expect(try open.args(of: MactermProtocol.ChannelOpen.self) == .init(session: "macterm-abc"))
        #expect(open == MactermProtocol.Request(id: 7, method: MactermProtocol.ChannelOpen.self, args: .init(session: "macterm-abc")))

        guard case let .response(opened) = try Self.control("channel.open result") else {
            Issue.record("not a response")
            return
        }
        #expect(opened.re == 7)
        #expect(try opened.result(of: MactermProtocol.ChannelOpen.self) == .init(channel: 2))

        guard case let .request(close) = try Self.control("channel.close request") else {
            Issue.record("not a request")
            return
        }
        #expect(try close.args(of: MactermProtocol.ChannelClose.self) == .init(channel: 2))

        guard case let .response(closed) = try Self.control("channel.close result") else {
            Issue.record("not a response")
            return
        }
        #expect(try closed.result(of: MactermProtocol.ChannelClose.self) == .init())
    }

    @Test
    func an_error_response_decodes_and_its_result_is_the_error() throws {
        guard case let .response(failed) = try Self.control("error") else {
            Issue.record("not a response")
            return
        }
        let info = MactermProtocol.ErrorInfo(code: "unknown_method", message: "No method pane.fly.", level: 3)
        #expect(failed == .init(re: 9, err: info))
        #expect(throws: ProtocolControlError.errorResponse(info)) {
            try failed.result(of: MactermProtocol.ChannelClose.self)
        }
    }

    @Test
    func an_error_code_reads_as_its_case_and_a_later_code_as_unknown() {
        #expect(MactermProtocol.ErrorInfo(code: "unknown_method", message: "").errorCode == .unknownMethod)
        #expect(MactermProtocol.ErrorInfo(code: "not_found", message: "").errorCode == .notFound)
        #expect(MactermProtocol.ErrorInfo(code: "on_fire", message: "").errorCode == .unknown("on_fire"))
    }

    @Test
    func an_event_of_a_later_build_decodes_as_unknown() throws {
        #expect(try MactermProtocol.Event(e: "pane.title").decoded() == .unknown("pane.title"))
    }

    @Test
    func an_event_batch_keeps_each_events_arguments_as_bytes() throws {
        let batch = MactermProtocol.EventBatch(seq: 41, ev: [
            .init(e: "pane.title", a: ProtocolRaw(Data([0x81, 0xA1, 0x74, 0xA2, 0x68, 0x78]))),
            .init(e: "pane.bell"),
        ])
        #expect(try Self.control("events") == .events(batch))
    }

    @Test
    func a_hello_from_a_later_build_decodes_with_its_new_role_as_unknown() throws {
        guard case let .hello(hello) = try Self.control("later hello") else {
            Issue.record("not a hello")
            return
        }
        #expect(hello.level == 9)
        #expect(hello.role == .unknown)
        #expect(hello.caps == ["tcc", "teleport"])
    }

    /// The model that `fixtures` in `schema.zig` builds: a project's tab
    /// with a split of a local and a remote pane.
    private static let tab = MactermProtocol.Tab(
        id: "t-1",
        customTitle: "build",
        root: .split(.init(
            id: "s-1",
            dir: .horizontal,
            ratio: 0.3,
            first: .pane(.init(
                id: "pane-1",
                session: "macterm-1",
                slug: "api",
                originPath: "/src/api",
                cwd: "/src/api/cmd",
                attention: .done
            )),
            second: .pane(.init(id: "pane-2", session: "macterm-2", host: "me@box", hostSessionDir: "/run/macterm"))
        )),
        focused: "pane-2"
    )

    private static let model = MactermProtocol.ModelData(
        epochHint: 5,
        importedV1: true,
        projects: [.init(id: "p-1", name: "api", path: "/src/api", color: "blue", sortOrder: 2, createdAt: 1_700_000_000_000)],
        workspaces: [.init(id: "p-1", kind: .project, tabs: [tab], activeTab: "t-1")],
        selection: .init(activeProject: "p-1")
    )

    /// Each typed value is also encoded here, and the frame must hold the
    /// same bytes: `Request` and `Response` compare their raw arguments.
    @Test
    func the_model_decodes_from_a_subscribe_result() throws {
        guard case let .response(response) = try Self.control("state.subscribe result") else {
            Issue.record("not a response")
            return
        }
        let result = MactermProtocol.StateSubscribe.Result(
            epoch: 5,
            seq: 12,
            model: Self.model,
            zoomed: [.init(tab: "t-1", pane: "pane-2")],
            sessions: [.init(id: "macterm-1", state: .running, build: "2.0.0", level: 3, pid: 501)],
            client: 77
        )
        #expect(try response.result(of: MactermProtocol.StateSubscribe.self) == result)
        #expect(response == .init(re: 10, method: MactermProtocol.StateSubscribe.self, result: result))
    }

    @Test
    func a_tab_with_a_split_tree_decodes_from_a_create_request() throws {
        guard case let .request(request) = try Self.control("tab.create request") else {
            Issue.record("not a request")
            return
        }
        let args = MactermProtocol.TabCreate.Args(workspace: "p-1", id: "t-1", root: Self.tab.root, title: "build")
        #expect(try request.args(of: MactermProtocol.TabCreate.self) == args)
        #expect(request == .init(id: 11, method: MactermProtocol.TabCreate.self, args: args))
    }

    @Test
    func a_model_batch_keeps_its_cause_and_its_events_decode() throws {
        guard case let .events(batch) = try Self.control("model events") else {
            Issue.record("not an event batch")
            return
        }
        let changed = MactermProtocol.TabChanged(workspace: "p-1", tab: Self.tab, zoomed: "pane-2")
        let order = MactermProtocol.TabOrder(workspace: "p-1", kind: .project, ids: ["t-1"], activeTab: "t-1")
        #expect(batch == .init(seq: 13, ev: [
            .init(e: MactermProtocol.TabChanged.name, a: ProtocolRaw(encoding: changed)),
            .init(e: MactermProtocol.TabOrder.name, a: ProtocolRaw(encoding: order)),
        ], cause: 11))
        #expect(try batch.ev.map { try $0.decoded() } == [.tabChanged(changed), .tabOrder(order)])
    }

    @Test
    func the_model_decodes_from_an_import_request() throws {
        guard case let .request(request) = try Self.control("model.import request") else {
            Issue.record("not a request")
            return
        }
        let args = MactermProtocol.ModelImport.Args(model: Self.model, source: "workspaces_v3.json")
        #expect(try request.args(of: MactermProtocol.ModelImport.self) == args)
        #expect(request == .init(id: 12, method: MactermProtocol.ModelImport.self, args: args))
    }

    /// Decodes a pane message and its fields, and builds it again from them.
    private static func paneMessage(_ body: Data) throws -> MactermProtocol.PaneMessage {
        let msg = try MessagePackReader.decode(MactermProtocol.PaneMessage.self, from: body)
        return switch msg.t {
        case MactermProtocol.Attach.name: try .init(msg.message(of: MactermProtocol.Attach.self))
        case MactermProtocol.Exit.name: try .init(msg.message(of: MactermProtocol.Exit.self))
        case MactermProtocol.Claim.name: try .init(msg.message(of: MactermProtocol.Claim.self))
        default: msg
        }
    }

    /// The pane message of a fixture on the pane channel.
    private static func pane(_ name: String) throws -> MactermProtocol.PaneMessage {
        let bytes = try #require(fixtures[name]?.bytes, "no fixture \(name)")
        let parsed = try #require(try ProtocolFrame.parse(bytes))
        #expect(parsed.frame.channel == 1)
        #expect(parsed.frame.kind == .msg)
        return try MessagePackReader.decode(MactermProtocol.PaneMessage.self, from: parsed.frame.body)
    }

    @Test
    func pane_messages_decode_with_their_fields_and_defaults() throws {
        let attach = try Self.pane("attach")
        #expect(attach.t == "attach")
        #expect(try attach.message(of: MactermProtocol.Attach.self) == .init(cols: 120, rows: 40, xpixel: 0, ypixel: 0))
        let exit = try Self.pane("exit").message(of: MactermProtocol.Exit.self)
        #expect(exit.code == 130)
        #expect(exit.signal == nil)
        #expect(try Self.pane("claim").message(of: MactermProtocol.Claim.self) == .init())
    }

    @Test
    func pane_bytes_pass_as_they_are() throws {
        let bytes = try #require(Self.fixtures["pane bytes"]?.bytes)
        let parsed = try #require(try ProtocolFrame.parse(bytes))
        #expect(parsed.frame == ProtocolFrame(channel: 3, kind: .bytes, body: Data("ls\r".utf8)))
    }

    @Test
    func the_schemas_own_rules_hold() {
        #expect(MactermProtocol.minLevel <= MactermProtocol.level)
        #expect(MactermProtocol.Hello.name == "hello")
        #expect(MactermProtocol.ChannelOpen.senders == [.local])
        #expect(MactermProtocol.Hello.senders == [.local, .session, .remote])
    }
}
