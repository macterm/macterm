import Foundation
@testable import Macterm
import Testing

struct ControlProtocolTests {
    // MARK: - Framing

    @Test
    func request_roundtrips_with_newline_framing() throws {
        let request = ControlRequest(command: "pane.list", args: ControlArgs(project: "demo", tab: "tab:2"))
        let encoded = try ControlProtocol.encode(request)
        #expect(encoded.last == 0x0A)
        let decoded = try ControlProtocol.decodeRequest(encoded)
        #expect(decoded.id == request.id)
        #expect(decoded.command == "pane.list")
        #expect(decoded.args == ControlArgs(project: "demo", tab: "tab:2"))
        #expect(decoded.v == ControlProtocol.minimumSupportedVersion)
    }

    @Test
    func response_roundtrips_success_and_failure() throws {
        let success = ControlResponse.success(
            id: "abc",
            data: ControlData(status: ControlStatusInfo(version: "1.0", pid: 42, activeProject: "p", activeProjectID: nil))
        )
        let decodedSuccess = try ControlProtocol.decodeResponse(ControlProtocol.encode(success))
        #expect(decodedSuccess.ok)
        #expect(decodedSuccess.id == "abc")
        #expect(decodedSuccess.data?.status?.pid == 42)
        #expect(decodedSuccess.error == nil)

        let failure = ControlResponse.failure(
            id: "def",
            error: ControlError(code: .notFound, message: "nope", action: "look elsewhere")
        )
        let decodedFailure = try ControlProtocol.decodeResponse(ControlProtocol.encode(failure))
        #expect(!decodedFailure.ok)
        #expect(decodedFailure.error?.code == .notFound)
        #expect(decodedFailure.error?.action == "look elsewhere")
    }

    /// The wire format the CLI emits, hand-built: guards against accidental
    /// key renames on the app side.
    @Test
    func app_decodes_hand_built_cli_request() throws {
        let json = #"{"v":1,"id":"x1","command":"session.info","args":{"session":"macterm-demo-abc123"}}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\n").utf8))
        #expect(decoded.command == "session.info")
        #expect(decoded.args?.session == "macterm-demo-abc123")
    }

    /// Unknown args keys must be ignored (forward compatibility: a newer CLI
    /// against an older app).
    @Test
    func unknown_args_fields_are_ignored() throws {
        let json = #"{"v":1,"id":"x2","command":"status","args":{"future_flag":"yes"}}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\n").utf8))
        #expect(decoded.command == "status")
        #expect(decoded.args == ControlArgs())
    }

    @Test(arguments: [nil, true, false] as [Bool?])
    func creation_focus_roundtrips_as_an_optional_field(focus: Bool?) throws {
        let request = ControlRequest(command: "tab.new", args: ControlArgs(focus: focus))
        let decoded = try ControlProtocol.decodeRequest(ControlProtocol.encode(request))
        #expect(decoded.args?.focus == focus)
    }

    // MARK: - Version gating (#499)

    /// `v` is the minimum server version a request needs, not the client's
    /// version: a request with no v2-only field keeps v1 so an older app still
    /// accepts it, while one carrying `focus` bumps to v2 so a server that
    /// doesn't speak v2 refuses it instead of silently dropping the field.
    @Test
    func request_v_is_the_minimum_server_version_needed() {
        let plain = ControlRequest(command: "tab.new", args: ControlArgs(project: "api"))
        #expect(plain.v == ControlProtocol.minimumSupportedVersion)

        let background = ControlRequest(command: "tab.new", args: ControlArgs(focus: false))
        #expect(background.v == ControlProtocol.focusFieldVersion)

        // The dangerous case is `false` (an older app would select what the
        // caller asked not to select); `true` still needs v2 because the field
        // itself is v2-only, but it is not reachable from the CLI today.
        let explicit = ControlRequest(command: "tab.new", args: ControlArgs(focus: true))
        #expect(explicit.v == ControlProtocol.focusFieldVersion)
    }

    /// A server must refuse a request whose minimum version exceeds its own,
    /// and the wire shape of that refusal round-trips.
    @Test
    func unsupported_version_failure_roundtrips() throws {
        let failure = ControlResponse.failure(
            id: "v2",
            error: ControlError(
                code: .unsupportedVersion,
                message: "the client needs control protocol v3, but Macterm speaks v2",
                action: "upgrade Macterm"
            )
        )
        let decoded = try ControlProtocol.decodeResponse(ControlProtocol.encode(failure))
        #expect(!decoded.ok)
        #expect(decoded.error?.code == .unsupportedVersion)
        #expect(decoded.error?.action == "upgrade Macterm")
    }

    @Test
    func error_codes_use_snake_case_raw_values() {
        #expect(ControlErrorCode.notFound.rawValue == "not_found")
        #expect(ControlErrorCode.unknownCommand.rawValue == "unknown_command")
        #expect(ControlErrorCode.noSurface.rawValue == "no_surface")
        #expect(ControlErrorCode.unsupportedVersion.rawValue == "unsupported_version")
        #expect(ControlErrorCode.badRequest.rawValue == "bad_request")
        #expect(ControlErrorCode.internalError.rawValue == "internal")
    }

    @Test
    func decode_tolerates_trailing_whitespace_and_crlf() throws {
        let json = #"{"v":1,"id":"x3","command":"status"}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\r\n").utf8))
        #expect(decoded.command == "status")
    }

    @Test
    func pane_response_without_execution_state_remains_decodable() throws {
        let json = #"""
        {
          "v": 1,
          "id": "old",
          "ok": true,
          "data": {
            "panes": [{
              "index": 1,
              "id": "p",
              "session": "macterm-demo",
              "tabIndex": 1,
              "tabID": "t",
              "title": "zsh",
              "focused": true
            }]
          }
        }
        """#
        let decoded = try ControlProtocol.decodeResponse(Data((json + "\n").utf8))
        #expect(decoded.data?.panes?.first?.state == nil)
    }

    @Test
    func project_response_without_index_remains_decodable() throws {
        let json = #"""
        {
          "v": 1,
          "id": "old",
          "ok": true,
          "data": {
            "projects": [{
              "id": "p",
              "name": "api",
              "path": "/tmp",
              "active": true,
              "loaded": true,
              "tabCount": 1
            }]
          }
        }
        """#
        let decoded = try ControlProtocol.decodeResponse(Data((json + "\n").utf8))
        #expect(decoded.data?.projects?.first?.name == "api")
        #expect(decoded.data?.projects?.first?.index == nil)
    }

    // MARK: - New verbs (#165/#166/#167)

    @Test
    func request_roundtrips_new_args_fields() throws {
        let args = ControlArgs(pane: "pane:2", scrollback: true, axis: "vertical", ratio: 0.42)
        let request = ControlRequest(command: "pane.resize-split", args: args)
        let decoded = try ControlProtocol.decodeRequest(ControlProtocol.encode(request))
        #expect(decoded.args?.scrollback == true)
        #expect(decoded.args?.axis == "vertical")
        #expect(decoded.args?.ratio == 0.42)
        #expect(decoded.args == args)
    }

    @Test
    func response_roundtrips_inspect_payload() throws {
        let inspect = ControlPaneInspect(
            id: "pane-id", session: "macterm-demo-abc123def456",
            cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 17, widthPx: 640, heightPx: 408,
            scrollbackTotal: 204, scrollbackOffset: 0, scrollbackLen: 24,
            altScreen: false, contentScale: 2.0,
            foregroundPID: 4242, foregroundArgv: ["hx", "src/main.rs"],
            processExited: false, needsConfirmQuit: true
        )
        let response = ControlResponse.success(id: "i1", data: ControlData(inspect: inspect))
        let decoded = try ControlProtocol.decodeResponse(ControlProtocol.encode(response))
        #expect(decoded.data?.inspect == inspect)
    }

    @Test
    func response_roundtrips_dump_payload() throws {
        let dump = ControlPaneDump(
            id: "pane-id", session: "macterm-demo-abc123def456",
            scrollback: true, bytes: 5, text: "hello"
        )
        let response = ControlResponse.success(id: "d1", data: ControlData(dump: dump))
        let decoded = try ControlProtocol.decodeResponse(ControlProtocol.encode(response))
        #expect(decoded.data?.dump == dump)
    }

    // MARK: - ssh.askpass, shared with the Zig `macterm askpass`

    /// `server/src/cli/fixtures/askpass.json`: `askpass.zig` sends each
    /// `request` and reads each `response` there. This side checks that the
    /// request is the one that the v1 CLI sends, and that the app's codec reads
    /// the response as the Zig CLI does.
    private struct AskpassFixture: Decodable {
        var name: String
        var prompt: String
        var mode: String?
        var response: String?
        var stdout: String
        var stderr: String
        var exit: Int
    }

    @Test
    func askpass_requests_and_replies_match_the_shared_fixtures() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Control
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("server/src/cli/fixtures/askpass.json")
        let data = try Data(contentsOf: url)
        let cases = try JSONDecoder().decode([AskpassFixture].self, from: data)
        let requests = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]]).map { $0["request"] as? [String: Any] }
        #expect(cases.contains { $0.response != nil })
        for (c, want) in zip(cases, requests) {
            let confirm = c.mode == "confirm"
            if let want {
                // The request of the v1 CLI (`AskpassCommand`), without its id.
                var args = ControlArgs()
                args.prompt = c.prompt
                args.confirm = confirm ? true : nil
                let line = try ControlProtocol.encode(ControlRequest(command: "ssh.askpass", args: args))
                var sent = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
                sent["id"] = nil
                #expect(NSDictionary(dictionary: sent).isEqual(to: want), "\(c.name)")
            }
            guard let raw = c.response else { continue }
            let response = try ControlProtocol.decodeResponse(Data(raw.replacingOccurrences(of: "$ID", with: "x").utf8))
            #expect(response.id == "x")
            if c.exit == 0 {
                let answer = try #require(response.data?.askpass?.answer, "\(c.name)")
                #expect(c.stdout == (confirm ? "" : answer + "\n"), "\(c.name)")
            } else {
                #expect(!response.ok, "\(c.name)")
                #expect(c.stderr == "macterm: \(response.error?.message ?? "")\n", "\(c.name)")
            }
        }
    }
}
