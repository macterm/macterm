import Foundation
@testable import Macterm
import Testing

/// `RemoteHost` with a fake connect: the "host" is the bundled server in a
/// runtime directory of its own on this Mac, reached with no ssh. The fake
/// decides when a connect ends, and whether it fails.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RemoteHostTests {
    // MARK: - The state and the waits

    @Test
    func every_pane_waits_for_one_connect_and_the_state_shows_its_steps() async throws {
        try await withFakeHost { fake in
            fake.holdsConnect = true
            let panes = [fake.pane(), fake.pane()]
            let asks = panes.map { pane in
                Task { try await fake.attachment(pane) }
            }
            try await until { fake.connects == [true] }
            #expect(fake.host.state.isTrying)
            fake.step(.awaitingConsent)
            guard case .awaitingConsent = fake.host.state else {
                Issue.record("state: \(fake.host.state)")
                return
            }
            fake.releaseConnect()
            for ask in asks {
                guard case let .channel(_, create) = try await ask.value else {
                    Issue.record("no channel")
                    return
                }
                #expect(create == fake.directory)
            }
            // One connect served both panes.
            #expect(fake.connects == [true])
            #expect(fake.host.link != nil)
        }
    }

    @Test
    func a_failed_connect_makes_the_host_unreachable_and_its_panes_lost_with_one_backoff() async throws {
        try await withFakeHost { fake in
            fake.fails = true
            let left = fake.pane()
            let right = fake.pane()
            for pane in [left, right] {
                await #expect(throws: RemoteHost.Failure.self) { try await fake.attachment(pane) }
                #expect(pane.isRemoteLinkLost)
                #expect(pane.remoteLinkBadge == .lost)
            }
            guard case .unreachable = fake.host.state else {
                Issue.record("state: \(fake.host.state)")
                return
            }
            let retryAt = try #require(fake.host.nextTryAt)
            #expect(fake.lost == ["fake", "fake"])

            // Both panes wait. The host's backoff holds the sweep's try: the
            // two lost panes are one streak, not two.
            let waits = [left, right].map { pane in Task { try await fake.host.nextTry(for: pane.sessionName) } }
            try await until { fake.waiters(left) == 1 && fake.waiters(right) == 1 }
            fake.host.reconnect(answered: false, now: retryAt - 1)
            #expect(!left.isRemoteReconnecting && !right.isRemoteReconnecting)
            fake.host.reconnect(answered: false, now: retryAt)
            #expect(left.remoteLinkBadge == .reconnecting && right.remoteLinkBadge == .reconnecting)
            for wait in waits {
                #expect(try await wait.value == false)
            }
            // The next step of the one streak: 20 s, not 5 s for each pane.
            #expect(fake.host.nextTryAt == retryAt + 20)
            // While the try runs, a later sweep starts no second try.
            fake.host.reconnect(answered: false, now: retryAt + 100)
            #expect(fake.host.nextTryAt == retryAt + 20)
        }
    }

    @Test
    func a_host_that_answers_again_lets_its_lost_panes_try_at_once() async throws {
        try await withFakeHost { fake in
            fake.fails = true
            let pane = fake.pane()
            await #expect(throws: RemoteHost.Failure.self) { try await fake.attachment(pane) }
            let wait = Task { try await fake.host.nextTry(for: pane.sessionName) }
            try await until { fake.waiters(pane) == 1 }
            fake.host.reconnect(answered: false, now: Date())
            #expect(!pane.isRemoteReconnecting)
            fake.host.reconnect(answered: true, now: Date())
            #expect(pane.isRemoteReconnecting)
            #expect(try await wait.value == false)
        }
    }

    /// A key in one lost pane connects. The host is reachable again, so the
    /// sweep that the connect starts lets its other lost panes try at once,
    /// past the backoff of the failed tries.
    @Test
    func a_connect_that_works_clears_the_backoff_for_the_other_lost_panes() async throws {
        try await withFakeHost { fake in
            fake.fails = true
            let keyed = fake.pane()
            let other = fake.pane()
            for pane in [keyed, other] {
                await #expect(throws: RemoteHost.Failure.self) { try await fake.attachment(pane) }
            }
            let wait = Task { try await fake.host.nextTry(for: other.sessionName) }
            try await until { fake.waiters(other) == 1 }
            #expect(fake.host.nextTryAt != nil)
            fake.host.reconnect(answered: false, now: Date())
            #expect(!other.isRemoteReconnecting)

            fake.fails = false
            guard case .channel = try await fake.attachment(keyed) else {
                Issue.record("no channel")
                return
            }
            #expect(fake.host.nextTryAt == nil)
            #expect(!keyed.isRemoteLinkLost)
            fake.host.reconnect(answered: false, now: Date())
            #expect(other.isRemoteReconnecting)
            #expect(try await wait.value == false)
        }
    }

    @Test
    func a_key_wakes_every_view_of_the_pane_and_may_ask() async throws {
        try await withFakeHost { fake in
            fake.fails = true
            let pane = fake.pane()
            await #expect(throws: RemoteHost.Failure.self) { try await fake.attachment(pane) }
            let views = (0 ..< 2).map { _ in Task { try await fake.host.nextTry(for: pane.sessionName) } }
            try await until { fake.waiters(pane) == 2 }
            fake.host.retry(pane.sessionName)
            #expect(pane.remoteLinkBadge == .reconnecting)
            for view in views {
                #expect(try await view.value == true)
            }
        }
    }

    @Test
    func a_cancelled_task_ends_its_wait() async throws {
        try await withFakeHost { fake in
            fake.holdsConnect = true
            let pane = fake.pane()
            let ask = Task { try await fake.attachment(pane) }
            try await until { fake.connects.count == 1 }
            ask.cancel()
            await #expect(throws: CancellationError.self) { try await ask.value }

            let wait = Task { try await fake.host.nextTry(for: pane.sessionName) }
            try await until { fake.waiters(pane) == 1 }
            wait.cancel()
            await #expect(throws: CancellationError.self) { try await wait.value }
            try await until { fake.waiters(pane) == 0 }
            fake.releaseConnect()
        }
    }

    @Test
    func a_key_during_a_quiet_connect_connects_again_and_may_ask() async throws {
        try await withFakeHost { fake in
            fake.holdsConnect = true
            let pane = fake.pane()
            let quiet = Task { try await fake.attachment(pane, prompts: false) }
            try await until { fake.connects == [false] }
            fake.host.retry(pane.sessionName)
            try await until { fake.connects == [false, true] }
            fake.releaseConnect()
            guard case .channel = try await quiet.value else {
                Issue.record("no channel")
                return
            }
        }
    }

    // MARK: - A pane's driver on the fake link

    /// The link stops: its pane is lost at once, with no key, and comes back
    /// on the sweep's try, with no question, to the same session.
    @Test
    func a_closed_link_makes_the_pane_lost_and_the_sweep_brings_it_back() async throws {
        try await withFakeHost { fake in
            let pane = fake.pane()
            let view = RecordingPaneHost()
            let driver = fake.driver(pane, view)
            defer { driver.stop() }
            driver.start()
            try await view.waitFor { $0.resets > 0 }
            driver.sendInput(Data("printf 'before-%s\\n' close\n".utf8))
            try await view.waitFor { $0.screen.contains("before-close") }
            try await until { pane.hostSessionDirectory != nil }

            try #require(fake.host.link).close()
            try await until { pane.isRemoteLinkLost && fake.waiters(pane) == 1 }
            #expect(pane.remoteLinkBadge == .lost)
            #expect(fake.host.link == nil)

            fake.host.reconnect(answered: false, now: Date())
            try await view.waitFor { $0.resets > 1 && $0.screen.contains("before-close") }
            try await until { !pane.isRemoteLinkLost && !pane.isRemoteReconnecting }
            #expect(fake.connects == [true, false])
        }
    }

    /// The host stops answering, with no read that ends: only the ping shows
    /// it. The pane is lost in seconds (the ping every 3 s, 3 s to answer),
    /// not after ssh's keepalive (about 45 s).
    @Test
    func a_host_that_stops_answering_makes_the_pane_lost_in_seconds() async throws {
        try await withFakeHost { fake in
            fake.watches = true
            let pane = fake.pane()
            let view = RecordingPaneHost()
            let driver = fake.driver(pane, view)
            defer { driver.stop() }
            driver.start()
            try await view.waitFor { $0.resets > 0 }
            let server = try #require(fake.host.link?.connection.serverPID)
            #expect(kill(server, SIGSTOP) == 0)
            defer { kill(server, SIGCONT) }
            let stopped = Date()
            try await until(seconds: 15) { pane.isRemoteLinkLost }
            #expect(pane.isRemoteLinkLost)
            #expect(Date().timeIntervalSince(stopped) < 10)
        }
    }

    /// A key in a lost pane connects at once, past the backoff, and its
    /// bytes are dropped: they were typed at a stale screen.
    @Test
    func a_key_in_a_lost_pane_connects_at_once_and_is_dropped() async throws {
        try await withFakeHost { fake in
            let pane = fake.pane()
            let view = RecordingPaneHost()
            let driver = fake.driver(pane, view)
            defer { driver.stop() }
            driver.start()
            try await view.waitFor { $0.resets > 0 }
            try await until { pane.hostSessionDirectory != nil }
            try #require(fake.host.link).close()
            try await until { pane.isRemoteLinkLost && fake.waiters(pane) == 1 }

            driver.sendInput(Data("printf 'dropped-%s\\n' key\n".utf8))
            try await view.waitFor { $0.resets > 1 }
            try await until { !pane.isRemoteLinkLost }
            #expect(fake.connects == [true, true])
            driver.sendInput(Data("printf 'after-%s\\n' key\n".utf8))
            try await view.waitFor { $0.screen.contains("after-key") }
            #expect(!view.snapshot().screen.contains("dropped-key"))
        }
    }

    @Test
    func a_pane_whose_session_is_gone_closes() async throws {
        try await withFakeHost { fake in
            let pane = fake.pane()
            // The session ran on the host, and the host has none now.
            pane.hostSessionDirectory = fake.directory
            let view = RecordingPaneHost()
            let driver = fake.driver(pane, view)
            defer { driver.stop() }
            driver.start()
            try await until { view.snapshot().exit != nil }
            #expect(fake.host.sessions[pane.sessionName] == nil)
        }
    }

    // MARK: - Fixture

    private func until(seconds: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        if !condition() { Issue.record("timed out") }
    }

    /// The bundled server in a new runtime directory, and a host whose
    /// connect gives a link to it.
    private func withFakeHost(_ body: (FakeHost) async throws -> Void) async throws {
        let bundled = try #require(LocalServer.bundled, "zmx/zmx missing from the built bundle. Run `mise run setup`.")
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "mt-\(UInt32.random(in: 0 ... .max))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var server = bundled
        server.directory = root.appending(path: "run", directoryHint: .isDirectory)
        server.stateDirectory = root.appending(path: "state", directoryHint: .isDirectory)
        let fake = FakeHost(server: server, directory: root.path)
        do {
            try await body(fake)
        } catch {
            await fake.cleanUp()
            throw error
        }
        await fake.cleanUp()
    }

    @MainActor
    private final class FakeHost {
        let server: LocalServer
        let directory: String
        let hosts: RemoteHosts
        /// The `prompts` of each connect, in order.
        private(set) var connects: [Bool] = []
        /// The destinations of each `hostLost`.
        private(set) var lost: [String] = []
        /// A connect waits for `releaseConnect`.
        var holdsConnect = false
        var fails = false
        /// The link pings its server, as a link over ssh does.
        var watches = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private var steps: [@MainActor (RemoteHost.Step) -> Void] = []

        var host: RemoteHost {
            hosts.host("fake")
        }

        init(server: LocalServer, directory: String) {
            self.server = server
            self.directory = directory
            var configuration = RemoteHosts.Configuration(key: "k", declines: .memory())
            configuration.hostDidConnect = { _ in }
            hosts = RemoteHosts(connections: .shared, servers: .shared, configuration: configuration)
            hosts.configuration.hostLost = { [weak self] in self?.lost.append($0) }
            hosts.configuration.open = { [weak self] _, prompts, step in
                guard let self else { throw CancellationError() }
                return try await connect(prompts: prompts, step: step)
            }
        }

        private func connect(prompts: Bool, step: @escaping @MainActor (RemoteHost.Step) -> Void) async throws -> RemoteHost.Opened {
            connects.append(prompts)
            steps.append(step)
            if holdsConnect {
                await withCheckedContinuation { held.append($0) }
            }
            if fails { throw RemoteServers.Failure.attachFailed("fake") }
            let connection = try await server.connect()
            let link = RemoteServers.Link(connection: connection, process: nil, installed: false, commands: 1)
            if watches { link.watch() }
            return .link(link)
        }

        func step(_ step: RemoteHost.Step) {
            steps.last?(step)
        }

        func releaseConnect() {
            holdsConnect = false
            let all = held
            held = []
            all.forEach { $0.resume() }
        }

        func pane() -> Pane {
            let pane = Pane(projectPath: "fake:\(directory)", projectID: UUID())
            let panes = panes
            panes.mutate { $0[pane.sessionName] = pane }
            hosts.pane = { [panes] session in panes.value[session] }
            return pane
        }

        private let panes = LockedBox<[String: Pane]>([:])

        func waiters(_ pane: Pane) -> Int {
            host.waiterCount(for: pane.sessionName)
        }

        func attachment(_ pane: Pane, prompts: Bool = true) async throws -> RemoteHost.Attachment {
            let host = try #require(hosts.host(of: pane))
            return try await host.attachment(for: pane.sessionName, pane: pane, directory: directory, prompts: prompts)
        }

        func driver(_ pane: Pane, _ view: RecordingPaneHost) -> RemotePaneDriver {
            RemotePaneDriver(name: pane.sessionName, surface: view, hosts: hosts, slowConnectAfter: .seconds(60))
        }

        /// Leaves no session and no server behind.
        func cleanUp() async {
            releaseConnect()
            guard let connection = try? ServerConnection.connect(path: server.socketPath) else { return }
            for session in await (try? connection.call(MactermProtocol.SessionList.self, .init()).sessions) ?? [] {
                _ = try? await connection.call(MactermProtocol.SessionKill.self, .init(id: session.id))
            }
            _ = try? await connection.call(MactermProtocol.ServerExit.self, .init())
            connection.close()
        }
    }
}
