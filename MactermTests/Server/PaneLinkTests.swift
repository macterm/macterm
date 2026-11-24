import Foundation
@testable import Macterm
import Testing

/// A pane's link against the bundled server, in a runtime directory of its
/// own (see `LocalServerTests`), with two views as two windows give.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaneLinkTests {
    @Test
    func two_views_give_the_pane_each_message_and_the_end_once() async throws {
        try await withServer { server in
            let link = PaneLink(name: "pl-\(UInt32.random(in: 0 ... .max))", transport: .local(TestServerEndpoint(server)))
            var titles = 0
            var ends = 0
            link.onEvent = { event in
                switch event {
                case .title: titles += 1
                case .ended: ends += 1
                default: break
                }
            }
            let launch = PaneSession.Launch(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/sh", "-c", "printf '\\033]2;pl-title\\007'; read l; exit 3"],
                env: []
            )
            let first = SurfaceChannelHost(view: nil)
            let second = SurfaceChannelHost(view: nil)
            let route = link.attach(first, launch: launch)
            // A second window's surface resolves a launch too: the link made
            // the session already, so it is not run.
            _ = link.attach(second, launch: launch)
            link.viewReady(first)
            link.viewReady(second)

            try await waitFor { titles > 0 }
            // Both channels got the title; the pane hears it once.
            try await Task.sleep(for: .milliseconds(300))
            #expect(titles == 1)

            route.sendInput(Data("bye\n".utf8))
            try await waitFor { ends > 0 }
            try await Task.sleep(for: .milliseconds(300))
            #expect(ends == 1)
            #expect(link.hasEnded)
        }
    }

    @Test
    func a_view_that_goes_leaves_the_session_running_for_the_other() async throws {
        try await withServer { server in
            let link = PaneLink(name: "pl-\(UInt32.random(in: 0 ... .max))", transport: .local(TestServerEndpoint(server)))
            var titles: [String] = []
            var ends = 0
            link.onEvent = { event in
                switch event {
                case let .title(title): titles.append(title)
                case .ended: ends += 1
                default: break
                }
            }
            let launch = PaneSession.Launch(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/sh", "-c", "while read l; do printf '\\033]2;%s\\007' \"$l\"; done"],
                env: []
            )
            let first = SurfaceChannelHost(view: nil)
            let second = SurfaceChannelHost(view: nil)
            let firstRoute = link.attach(first, launch: launch)
            let secondRoute = link.attach(second, launch: launch)
            link.viewReady(first)
            link.viewReady(second)
            firstRoute.sendInput(Data("one\n".utf8))
            try await waitFor { titles.contains("one") }

            // The first window closes: the second view's channel now counts.
            link.detach(first)
            secondRoute.sendInput(Data("two\n".utf8))
            try await waitFor { titles.contains("two") }
            #expect(ends == 0)
            #expect(!link.hasEnded)
            link.detach(second)
        }
    }

    /// One view counts for the pane: the first that is ready. It changes
    /// only when a view comes or goes.
    @Test
    func the_first_ready_view_counts_until_it_goes() {
        // An endpoint with no server: the rule needs no session.
        let link = PaneLink(name: "pl-count", transport: .local(FakeEndpoint([])))
        let launch = PaneSession.Launch(cwd: nil, argv: nil, env: [])
        let first = SurfaceChannelHost(view: nil)
        let second = SurfaceChannelHost(view: nil)
        _ = link.attach(first, launch: launch)
        _ = link.attach(second, launch: launch)
        #expect(!link.counts(first) && !link.counts(second), "no view is ready")

        link.viewReady(second)
        #expect(link.counts(second))
        link.viewReady(first)
        #expect(link.counts(first), "the first ready view in the order the views came")
        #expect(!link.counts(second))

        link.detach(first)
        #expect(link.counts(second))
        link.detach(second)
        #expect(!link.counts(second))
    }

    // MARK: - Support

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("timed out")
    }

    private func withServer(_ body: (LocalServer) async throws -> Void) async throws {
        let bundled = try #require(LocalServer.bundled, "zmx/zmx missing from the built bundle. Run `mise run setup`.")
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "mt-\(UInt32.random(in: 0 ... .max))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var server = bundled
        server.directory = root.appending(path: "run", directoryHint: .isDirectory)
        do {
            try await body(server)
        } catch {
            await Self.cleanUp(server)
            throw error
        }
        await Self.cleanUp(server)
    }

    private static func cleanUp(_ server: LocalServer) async {
        guard let connection = try? ServerConnection.connect(path: server.socketPath) else { return }
        for session in await (try? connection.call(MactermProtocol.SessionList.self, .init()).sessions) ?? [] {
            _ = try? await connection.call(MactermProtocol.SessionKill.self, .init(id: session.id))
        }
        _ = try? await connection.call(MactermProtocol.ServerExit.self, .init())
        connection.close()
    }
}
