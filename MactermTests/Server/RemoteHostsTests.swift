import Foundation
@testable import Macterm
import Testing

@MainActor
struct RemoteHostsTests {
    // MARK: - Pure rules

    @Test
    func a_running_session_attaches_and_a_missing_one_is_made_only_when_it_never_ran_on_the_host() {
        func step(running: Bool = false, directory: String? = nil, justCreated: Bool = false) -> RemoteHosts.Step {
            RemoteHosts.step(running: running, sessionDirectory: directory, justCreated: justCreated, projectDirectory: "~/app")
        }
        #expect(step(running: true, directory: "/srv") == .attach)
        // A new pane, or one from before v2: a new session, no question.
        #expect(step() == .create(directory: "~/app"))
        // Its session ran on the host and is gone (a host restart): the
        // pane closes.
        #expect(step(directory: "/srv/app/src") == .gone)
        // The app made it a moment ago: it counts as made, in its folder.
        #expect(step(directory: "/srv/app/src", justCreated: true) == .create(directory: "/srv/app/src"))
    }

    @Test
    func a_pane_that_closed_ends_its_view_and_a_local_pane_has_no_host() async throws {
        let hosts = RemoteHosts(connections: .shared, servers: .shared, configuration: .init(key: "k", declines: .memory()))
        hosts.pane = { _ in nil }
        let view = RecordingPaneHost()
        let driver = RemotePaneDriver(name: "macterm-x-1", surface: view, hosts: hosts)
        defer { driver.stop() }
        driver.start()
        try await view.waitFor { $0.exit != nil }
        // A local pane has no host: its view ends too.
        let local = Pane(projectPath: "/tmp", projectID: UUID())
        #expect(hosts.host(of: local) == nil)
        hosts.pane = { _ in local }
        let localView = RecordingPaneHost()
        let localDriver = RemotePaneDriver(name: local.sessionName, surface: localView, hosts: hosts)
        defer { localDriver.stop() }
        localDriver.start()
        try await localView.waitFor { $0.exit != nil }
    }

    // MARK: - Against a local sshd

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func one_login_serves_every_pane_and_the_host_foreground_reaches_the_pane() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let panes = (0 ..< 3).map { _ in fixture.pane() }
            var running: [Fixture.Running] = []
            defer { running.forEach { $0.stop() } }
            for pane in panes {
                let session = try await fixture.start(pane)
                running.append(session)
                session.type("printf 'ready-%s\\n' \(pane.sessionName)\n")
                try await session.host.waitFor { $0.screen.contains("ready-\(pane.sessionName)") }
                #expect(pane.hostSessionDirectory == fixture.directory)
            }
            #expect(host.sshd.acceptedLogins() == 1)
            #expect(host.connections.logins["box"] == 1)

            // The host pushes the foreground of the session on the channel,
            // so a program names the tab and shows its logo with no probe.
            running[0].type("sleep 30\n")
            try await running[0].host.waitFor { $0.foreground?.idle == false }
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_background_read_runs_on_the_hosts_server_with_no_login_of_its_own() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            // No connection yet: a background read never logs in.
            #expect(await fixture.hosts.run(["/bin/sh", "-c", "true"], destination: "box", timeout: .seconds(5)) == nil)
            #expect(host.sshd.acceptedLogins() == 0)

            _ = try await fixture.attach(fixture.pane())
            #expect(fixture.ready == ["box"])
            let result = try #require(
                await fixture.hosts.run(["/bin/sh", "-c", "printf read-%s ok; exit 3"], destination: "box", timeout: .seconds(5))
            )
            #expect(String(decoding: result.output.bytes, as: UTF8.self) == "read-ok")
            #expect(result.code == 3)
            #expect(host.sshd.acceptedLogins() == 1)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_dropped_link_waits_dimmed_and_heals_on_a_trigger() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let pane = fixture.pane()
            let first = try await fixture.start(pane)
            defer { first.stop() }
            first.type("printf 'before-%s\\n' drop\n")
            try await first.host.waitFor { $0.screen.contains("before-drop") }

            // The link drops: the channel ends, and the driver reports it.
            host.sshd.dropConnections()
            try await first.host.waitFor { $0.linkLost > 0 }
            // No line goes into the pane: its badge shows the state.
            fixture.host.lost(pane.sessionName, pane: pane)
            #expect(pane.isRemoteLinkLost)
            #expect(pane.isDisconnected)
            #expect(fixture.lostHosts == ["box"])

            // The sweep wakes the pane; it logs in again with no question and
            // attaches to the same session, which replays its screen.
            #expect(try await fixture.sweep(pane) == false)
            let second = try await fixture.start(pane, prompts: false)
            defer { second.stop() }
            try await second.host.waitFor { $0.screen.contains("before-drop") }
            #expect(!pane.isRemoteLinkLost)
            #expect(host.sshd.acceptedLogins() == 2)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_host_that_stops_answering_on_the_roaming_link_is_quiet_until_it_answers_again() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host, roaming: true)
            let pane = fixture.pane()
            let first = try await fixture.start(pane)
            defer { first.stop() }
            // The roaming link opens in the background and becomes the
            // host's link.
            var deadline = Date().addingTimeInterval(20)
            var link = try await fixture.attach(pane).link
            while !link.isRoaming, Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
                link = try await fixture.attach(pane).link
            }
            #expect(link.isRoaming)
            #expect(fixture.hosts.quietDestinations.isEmpty)

            // The host's server stops: no packet comes back over UDP.
            let server = try host.serverPID()
            #expect(kill(server, SIGSTOP) == 0)
            defer { kill(server, SIGCONT) }
            deadline = Date().addingTimeInterval(20)
            while !fixture.hosts.quietDestinations.contains("box"), Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(fixture.hosts.quietDestinations == ["box"])

            // The server goes on: the next keepalive comes back.
            #expect(kill(server, SIGCONT) == 0)
            deadline = Date().addingTimeInterval(20)
            while !fixture.hosts.quietDestinations.isEmpty, Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(fixture.hosts.quietDestinations.isEmpty)
            // The same link heals: it was not dropped and opened again.
            #expect(try await fixture.attach(pane).link === link)
        }
    }

    /// 0381: a pane that became lost while the host's server was frozen
    /// attached only at the next backoff step (up to 60 s) or at a key. The
    /// quiet roaming link that hears the host again is the sign that the
    /// host answers: the app hears it once, and the sweep's try attaches
    /// the pane with no key.
    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_lost_pane_attaches_with_no_key_soon_after_its_quiet_host_answers_again() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host, roaming: true)
            let pane = fixture.pane()
            fixture.hosts.pane = { _ in pane }
            let first = try await fixture.start(pane)
            defer { first.stop() }
            first.type("printf 'before-%s\\n' freeze\n")
            try await first.host.waitFor { $0.screen.contains("before-freeze") }
            var deadline = Date().addingTimeInterval(20)
            while try await !fixture.attach(pane).link.isRoaming, Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }

            // The host's server stops, and the host becomes quiet. The pane
            // reports its link lost, as a driver does when the ping of the
            // ssh standby fails.
            let server = try host.serverPID()
            #expect(kill(server, SIGSTOP) == 0)
            defer { kill(server, SIGCONT) }
            fixture.host.lost(pane.sessionName, pane: pane)
            deadline = Date().addingTimeInterval(20)
            while !fixture.hosts.quietDestinations.contains("box"), Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(fixture.hosts.quietDestinations == ["box"])

            // A sweep's try while the host is down fails, and asks nothing.
            let wait = Task { try await fixture.host.nextTry(for: pane.sessionName) }
            try await fixture.untilWaiting(pane)
            fixture.hosts.reconnect(["box"])
            #expect(pane.isRemoteReconnecting)
            #expect(try await wait.value == false)
            await #expect(throws: RemoteHost.Failure.self) { try await fixture.attach(pane, prompts: false) }
            #expect(pane.isRemoteLinkLost)
            #expect(fixture.answered.isEmpty)

            // The server goes on. The host answers once, within a few
            // keepalives.
            #expect(kill(server, SIGCONT) == 0)
            let healed = Date()
            deadline = healed.addingTimeInterval(10)
            while fixture.answered.isEmpty, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(fixture.answered == ["box"])

            // What the sweep does then (`AppState.lostDestinations`, then the
            // host with its backoff cleared): a try with no key. The pane
            // attaches to its session, which replays its screen.
            #expect(try await fixture.sweep(pane, answered: true) == false)
            let second = try await fixture.start(pane, prompts: false)
            defer { second.stop() }
            try await second.host.waitFor { $0.screen.contains("before-freeze") }
            #expect(!pane.isRemoteLinkLost)
            #expect(Date().timeIntervalSince(healed) < 10)
            #expect(fixture.answered == ["box"])
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_pane_lost_in_a_short_freeze_attaches_with_no_key_soon_after_the_host_answers() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host, roaming: true)
            let pane = fixture.pane()
            fixture.hosts.pane = { _ in pane }
            let first = try await fixture.start(pane)
            defer { first.stop() }
            first.type("printf 'before-%s\\n' pause\n")
            try await first.host.waitFor { $0.screen.contains("before-pause") }
            var deadline = Date().addingTimeInterval(20)
            while try await !fixture.attach(pane).link.isRoaming, Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(fixture.answered.isEmpty)

            // The host's server stops for less than `quietAfter`. The pane
            // reports its link lost, as a driver does when the ping of the
            // ssh standby fails (after about 6 s). The link never becomes
            // quiet.
            let server = try host.serverPID()
            #expect(kill(server, SIGSTOP) == 0)
            defer { kill(server, SIGCONT) }
            fixture.host.lost(pane.sessionName, pane: pane)
            try await Task.sleep(for: .milliseconds(LinkTransport.answersAfter + 500))
            #expect(fixture.hosts.quietDestinations.isEmpty)
            #expect(pane.isRemoteLinkLost)
            #expect(fixture.answered.isEmpty)

            // The server goes on. The host answers once, within about one
            // keepalive.
            #expect(kill(server, SIGCONT) == 0)
            let resumed = Date()
            deadline = resumed.addingTimeInterval(10)
            while fixture.answered.isEmpty, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(fixture.answered == ["box"])
            let answered = Date()
            #expect(answered.timeIntervalSince(resumed) < 5)

            // What the sweep does then: a try with no key. The pane attaches
            // within about 5 s, and its session replays its screen.
            #expect(try await fixture.sweep(pane, answered: true) == false)
            let second = try await fixture.start(pane, prompts: false)
            defer { second.stop() }
            try await second.host.waitFor { $0.screen.contains("before-pause") }
            #expect(!pane.isRemoteLinkLost)
            #expect(Date().timeIntervalSince(answered) < 5)
            #expect(fixture.answered == ["box"])
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_killed_ssh_connection_dims_the_pane_and_a_key_connects_again() async throws {
        try await withSSHDHost { host in
            try await lostConnection(host, signal: "TERM", byKey: true)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_hung_ssh_connection_dims_the_pane_and_a_key_connects_again() async throws {
        try await withSSHDHost { host in
            try await lostConnection(host, signal: "STOP", byKey: true)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_killed_ssh_connection_connects_again_by_itself() async throws {
        try await withSSHDHost { host in
            try await lostConnection(host, signal: "TERM", byKey: false)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_slow_try_shows_reconnecting_until_the_pane_attaches() async throws {
        try await withSSHDHost { host in
            try await lostConnection(host, signal: "TERM", byKey: false, slowTry: true)
        }
    }

    /// After a restart of the app, a pane whose session ran on the host
    /// connects for the first time. A slow connect shows `Reconnecting`, and
    /// the attach clears it. A new pane in the same connect shows nothing.
    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_slow_first_connect_of_a_restored_pane_shows_reconnecting() async throws {
        try await withSSHDHost { host in
            let before = Fixture(host)
            let restored = before.pane()
            before.hosts.pane = { _ in restored }
            let first = RemotePaneDriver(name: restored.sessionName, surface: RecordingPaneHost(), hosts: before.hosts)
            first.start()
            let deadline = Date().addingTimeInterval(30)
            while restored.hostSessionDirectory == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(restored.hostSessionDirectory == before.directory)
            // The app quits: the channel and the login end, the session stays.
            first.stop()
            host.sshd.dropConnections()

            // The next login takes 4 s to reach the host.
            try host.sshd.addToConfig("ProxyCommand /bin/sh -c 'sleep 4; exec /usr/bin/nc %h %p'")
            let after = Fixture(host)
            let fresh = after.pane()
            after.hosts.pane = { $0 == restored.sessionName ? restored : fresh }
            let views = [RecordingPaneHost(), RecordingPaneHost()]
            let drivers = zip([restored, fresh], views).map { pane, view in
                RemotePaneDriver(name: pane.sessionName, surface: view, hosts: after.hosts, slowConnectAfter: .seconds(1))
            }
            defer { drivers.forEach { $0.stop() } }
            drivers.forEach { $0.start() }
            try await Task.sleep(for: .seconds(2))
            #expect(restored.remoteLinkBadge == .reconnecting)
            #expect(!restored.isRemoteLinkLost)
            #expect(fresh.remoteLinkBadge == nil)

            try await views[0].waitFor { $0.resets > 0 }
            try await views[1].waitFor { $0.resets > 0 }
            let attached = Date().addingTimeInterval(10)
            while restored.remoteLinkBadge != nil, Date() < attached {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(restored.remoteLinkBadge == nil)
            #expect(fresh.remoteLinkBadge == nil)
        }
    }

    /// A lost pane runs the app's sweep: the default `hostLost` posts the
    /// host on the next turn of the main queue, after the pane waits for its
    /// try.
    @Test
    func a_lost_pane_names_its_host_to_the_sweep() async throws {
        let configuration = RemoteHosts.Configuration(key: nil, declines: .memory())
        let objects = LockedBox<[String]>([])
        let observer = NotificationCenter.default.addObserver(forName: .remoteLinkDidStop, object: nil, queue: nil) { note in
            if let object = note.object as? String { objects.mutate { $0.append(object) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let destination = "host-\(UUID().uuidString)"
        configuration.hostLost(destination)
        #expect(!objects.value.contains(destination))
        let deadline = Date().addingTimeInterval(5)
        while !objects.value.contains(destination), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(objects.value.contains(destination))
    }

    /// The first connect of a pane that came back after a restart fails
    /// after a slow start: the badge changes from `Reconnecting` to
    /// `Connection Lost`, and the failure is a failed try, so the sweep
    /// waits its backoff before the next try.
    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_failed_slow_first_connect_of_a_restored_pane_shows_connection_lost() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let pane = fixture.pane()
            // The session ran on the host before the restart.
            pane.hostSessionDirectory = fixture.directory
            fixture.hosts.pane = { _ in pane }
            // The login fails after 4 s.
            try host.sshd.addToConfig("ProxyCommand /bin/sh -c 'sleep 4; exit 1'")
            let driver = RemotePaneDriver(
                name: pane.sessionName, surface: RecordingPaneHost(), hosts: fixture.hosts, slowConnectAfter: .seconds(1)
            )
            defer { driver.stop() }
            driver.start()
            try await Task.sleep(for: .seconds(2))
            #expect(pane.remoteLinkBadge == .reconnecting)
            let deadline = Date().addingTimeInterval(30)
            while pane.remoteLinkBadge != .lost, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(pane.remoteLinkBadge == .lost)
            // A failed try: the sweep waits the host's backoff.
            #expect(fixture.host.backoff.nextAttempt != nil)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func an_automatic_try_asks_nothing_and_a_key_logs_in() async throws {
        try await withSSHDHost(passphrase: "open sesame") { host in
            try await lostConnection(host, signal: "TERM", byKey: false, needsLogin: true)
        }
    }

    /// Two windows show one pane. The link stops with nothing typed; then a
    /// key, or the sweep with no key, brings both views back. `needsLogin`:
    /// the key has a passphrase, so the sweep's quiet try fails and asks
    /// nothing, and only a key logs in.
    private func lostConnection(
        _ host: SSHDHost,
        signal: String,
        byKey: Bool,
        needsLogin: Bool = false,
        slowTry: Bool = false
    ) async throws {
        let fixture = Fixture(host)
        let pane = fixture.pane()
        fixture.hosts.pane = { _ in pane }
        let left = RecordingPaneHost()
        let right = RecordingPaneHost()
        let drivers = [left, right].map { RemotePaneDriver(name: pane.sessionName, surface: $0, hosts: fixture.hosts) }
        defer { drivers.forEach { $0.stop() } }
        drivers.forEach { $0.start() }
        try await left.waitFor { $0.resets > 0 }
        drivers[0].sendInput(Data("printf 'before-%s\\n' kill\n".utf8))
        try await left.waitFor { $0.screen.contains("before-kill") }
        try await right.waitFor { $0.screen.contains("before-kill") }
        // The first attach's lead message marks the folder: the session ran.
        #expect(pane.hostSessionDirectory == fixture.directory)
        let resets = [left.snapshot().resets, right.snapshot().resets]
        let questions = host.askpassQuestions

        try host.signalConnection(signal: signal)
        let deadline = Date().addingTimeInterval(20)
        while !pane.isRemoteLinkLost, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(pane.remoteLinkBadge == .lost)
        #expect(fixture.lostHosts.contains("box"))
        // The badge shows it: no line goes into either view.
        #expect(!left.snapshot().screen.contains("onnection"))
        #expect(!right.snapshot().screen.contains("onnection"))

        if needsLogin {
            // The sweep's try asks nothing, fails, and the badge says so.
            try await fixture.untilWaiting(pane)
            fixture.hosts.reconnect(["box"])
            #expect(pane.isRemoteReconnecting)
            while pane.isRemoteReconnecting, Date() < deadline.addingTimeInterval(20) {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(pane.isRemoteLinkLost && !pane.isRemoteReconnecting)
            #expect(host.askpassQuestions == questions)
        }
        if byKey || needsLogin {
            // A key starts a try at once, and its bytes are dropped: they
            // were typed at a stale screen.
            drivers[0].sendInput(Data("printf 'dropped-%s\\n' key\n".utf8))
        } else {
            // The sweep, with no key.
            if slowTry {
                // The next login takes 3 s to reach the host.
                try host.sshd.addToConfig("ProxyCommand /bin/sh -c 'sleep 3; exec /usr/bin/nc %h %p'")
            }
            try await fixture.untilWaiting(pane)
            fixture.hosts.reconnect(["box"])
            #expect(pane.remoteLinkBadge == .reconnecting)
            if slowTry {
                try await Task.sleep(for: .seconds(1))
                // Still trying: the badge says so, in every view of the pane.
                #expect(pane.remoteLinkBadge == .reconnecting)
            }
        }
        // Both views attach to the same session and replay its screen.
        try await left.waitFor { $0.resets > resets[0] && $0.screen.contains("before-kill") }
        try await right.waitFor { $0.resets > resets[1] && $0.screen.contains("before-kill") }
        #expect(!pane.isRemoteLinkLost && !pane.isRemoteReconnecting)
        if needsLogin { #expect(host.askpassQuestions > questions) }
        drivers[0].sendInput(Data("printf 'after-%s\\n' key\n".utf8))
        try await left.waitFor { $0.screen.contains("after-key") }
        #expect(!left.snapshot().screen.contains("dropped-key"))
        #expect(host.sshd.acceptedLogins() == 2)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_key_in_one_lost_pane_brings_back_every_lost_pane_of_the_host() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let left = fixture.pane()
            let right = fixture.pane()
            let first = try await fixture.start(left)
            defer { first.stop() }
            let second = try await fixture.start(right)
            defer { second.stop() }
            second.type("printf 'right-%s\\n' up\n")
            try await second.host.waitFor { $0.screen.contains("right-up") }

            host.sshd.dropConnections()
            try await first.host.waitFor { $0.linkLost > 0 }
            try await second.host.waitFor { $0.linkLost > 0 }
            for pane in [left, right] {
                fixture.host.lost(pane.sessionName, pane: pane)
                #expect(pane.isRemoteLinkLost)
            }
            let rightWait = Task { try await fixture.host.nextTry(for: right.sessionName) }
            try await fixture.untilWaiting(right)

            // A key in the left pane logs in again. The link that came back
            // is a trigger: the sweep wakes the right pane, which attaches
            // with no key and no second login.
            let logins = fixture.connected.count
            let again = try await fixture.start(left)
            defer { again.stop() }
            #expect(fixture.connected.dropFirst(logins) == ["box"])
            #expect(fixture.host.waiterCount(for: right.sessionName) == 1)
            fixture.hosts.reconnect(["box"])
            #expect(try await rightWait.value == false)
            let rightAgain = try await fixture.start(right, prompts: false)
            defer { rightAgain.stop() }
            try await rightAgain.host.waitFor { $0.screen.contains("right-up") }
            #expect(!right.isRemoteLinkLost)
            #expect(host.sshd.acceptedLogins() == 2)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_pane_whose_session_is_gone_from_the_host_closes() async throws {
        try await withSSHDHost { host in
            // The host restarts at once: no grace for a new session.
            let fixture = Fixture(host, creationGrace: 0)
            let pane = fixture.pane()
            let first = try await fixture.start(pane)
            first.type("printf 'up-%s\\n' 1\n")
            try await first.host.waitFor { $0.screen.contains("up-1") }
            first.stop()
            #expect(pane.hostSessionDirectory == fixture.directory)

            // The host restarts: its server and sessions are gone, so the
            // pane closes. No new shell takes its place.
            try await host.stopServer()
            #expect(try await fixture.ask(pane).isEnded)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_second_view_that_asks_before_the_new_session_starts_makes_it_too() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let pane = fixture.pane()
            _ = try await fixture.attach(pane)
            // No attach yet: the folder does not count.
            #expect(pane.hostSessionDirectory == nil)
            // The first pane has not made its session yet: the host has no
            // session. A second window's view of the pane asks now.
            let (_, create) = try await fixture.attach(pane)
            #expect(create == fixture.directory)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_pane_whose_create_never_attached_is_made_again_and_not_closed() async throws {
        try await withSSHDHost { host in
            // The grace is over at once, as after a failed create.
            let fixture = Fixture(host, creationGrace: 0)
            let pane = fixture.pane()
            _ = try await fixture.attach(pane)
            // The create never ran: the pane asks again, and gets a new
            // session, not a close.
            let (_, create) = try await fixture.attach(pane)
            #expect(create == fixture.directory)
            #expect(pane.hostSessionDirectory == nil)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_new_session_gets_the_folder_and_the_settled_terminal_environment_from_the_host() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let pane = fixture.pane()
            let (link, create) = try await fixture.attach(pane)
            let directory = try #require(create)
            let made = try #require(await fixture.hosts.createLaunch(link: link, directory: directory))
            #expect(made.note == nil)
            #expect(made.launch.cwd?.hasPrefix("/") == true)
            #expect(made.launch.env.contains("COLORTERM=truecolor"))
            #expect(made.launch.env.contains("TERM_PROGRAM=ghostty"))
            #expect(made.launch.env.contains { $0.hasPrefix("TERM=") })
            let missing = try #require(await fixture.hosts.createLaunch(link: link, directory: "/no/such/folder/here"))
            #expect(missing.note == "macterm: cannot cd to /no/such/folder/here")
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_declined_server_gives_plain_shells_and_asks_once() async throws {
        try await withSSHDHost(answer: false) { host in
            let fixture = Fixture(host)
            for _ in 0 ..< 2 {
                let pane = fixture.pane()
                let answer = try await fixture.ask(pane)
                guard case let .plain(arguments) = answer else {
                    Issue.record("no plain shell: \(answer)")
                    return
                }
                #expect(arguments.last?.contains("connect") == false)
            }
            #expect(host.asked == ["box"])
            #expect(fixture.hosts.declined == ["box"])
            #expect(fixture.hosts.plainDestinations == ["box"])
            // A lost connection drops the host, and the host stays plain.
            let lost = fixture.pane()
            _ = fixture.hosts.host(of: lost)
            fixture.host.lost(lost.sessionName, pane: lost)
            #expect(lost.isRemoteLinkLost)
            #expect(fixture.hosts.plainDestinations == ["box"])
            // A second decline from Settings keeps the host plain.
            await #expect(throws: RemoteServers.Failure.self) { try await fixture.hosts.installServer("box") }
            #expect(fixture.hosts.plainDestinations == ["box"])
        }
    }

    // MARK: - The folder check of a new project (0358)

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_new_project_finds_its_folder_over_ssh_then_on_the_hosts_server_and_the_login_stays_for_its_panes() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            #expect(await fixture.hosts.checkFolder(fixture.directory, destination: "box") == .exists)
            #expect(await fixture.hosts.checkFolder("~", destination: "box") == .exists)
            #expect(await fixture.hosts.checkFolder("~/none-\(UUID().uuidString)", destination: "box") == .missing)
            #expect(fixture.ready == ["box"])
            // The project's first pane uses the same login.
            _ = try await fixture.attach(fixture.pane())
            #expect(host.sshd.acceptedLogins() == 1)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_new_project_finds_its_folder_over_ssh_when_the_host_has_no_server() async throws {
        try await withSSHDHost(answer: false) { host in
            let fixture = Fixture(host)
            #expect(await fixture.hosts.checkFolder(fixture.directory, destination: "box") == .exists)
            #expect(await fixture.hosts.checkFolder("~/none-\(UUID().uuidString)", destination: "box") == .missing)
            #expect(fixture.hosts.plainDestinations == ["box"])
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_missing_folder_is_told_before_the_install_question() async throws {
        // 0384: a wrong folder must not cost a server install first.
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            #expect(await fixture.hosts.checkFolder("~/none-\(UUID().uuidString)", destination: "box") == .missing)
            #expect(host.asked.isEmpty)
            #expect(fixture.ready.isEmpty)
            #expect(await fixture.hosts.checkFolder(fixture.directory, destination: "box") == .exists)
            #expect(host.asked == ["box"])
            #expect(fixture.ready == ["box"])
            #expect(host.sshd.acceptedLogins() == 1)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func the_folder_check_needs_no_host_script_of_the_bundle() async throws {
        // 0358: a bundle with no host scripts refused every host at once.
        try await withSSHDHost(answer: false) { host in
            let fixture = Fixture(host, scripts: nil)
            #expect(await fixture.hosts.checkFolder(fixture.directory, destination: "box") == .exists)
            #expect(await fixture.hosts.checkFolder("~/none-\(UUID().uuidString)", destination: "box") == .missing)
        }
    }

    @Test
    func a_host_name_that_is_not_valid_is_unreachable() async {
        let hosts = RemoteHosts(connections: .shared, servers: .shared, configuration: .init(key: "k", declines: .memory()))
        #expect(await hosts.checkFolder("/tmp", destination: "-oProxyCommand=x") == .unreachable)
    }

    // MARK: - The probe of a new session

    @Test
    func the_probe_output_gives_the_folder_the_environment_and_a_note_when_the_folder_is_missing() throws {
        let found = try #require(RemoteHosts.parseCreateProbe(
            "ok\n/srv/app\nTERM=xterm-256color\nHOME=/home/a\nnoise\n",
            directory: "~/app"
        ))
        #expect(found.launch.cwd == "/srv/app")
        #expect(found.launch.env == ["TERM=xterm-256color", "HOME=/home/a"])
        #expect(found.note == nil)
        let home = try #require(RemoteHosts.parseCreateProbe("home\n/home/a\nTERM=x\n", directory: "~/gone"))
        #expect(home.note == "macterm: cannot cd to ~/gone")
        #expect(RemoteHosts.parseCreateProbe("ok\nrelative\nTERM=x\n", directory: "~") == nil)
    }

    // MARK: - Fixture

    /// A `RemoteHosts` over the host's connection and server, and panes of
    /// a project on it.
    @MainActor
    private final class Fixture {
        let hosts: RemoteHosts
        let directory: String
        private let connections = LockedBox<[String]>([])
        /// The hosts whose link came back (`hostDidConnect`).
        var connected: [String] { connections.value }
        private let readyHosts = LockedBox<[String]>([])
        private let lost = LockedBox<[String]>([])
        private let answers = LockedBox<[String]>([])
        /// The hosts whose quiet roaming link heard them again
        /// (`hostAnswered`), in order.
        var answered: [String] { answers.value }
        /// The hosts of each pane that became lost (`hostLost`), in order.
        var lostHosts: [String] { lost.value }

        /// The hosts whose link became ready, in order.
        var ready: [String] {
            readyHosts.value
        }

        var host: RemoteHost {
            hosts.host("box")
        }

        /// `roaming`: a roaming link (UDP) opens after the ssh connect.
        /// `scripts`: the host scripts of the bundle; nil as in a bundle
        /// without them.
        init(
            _ host: SSHDHost,
            creationGrace: TimeInterval = 30,
            roaming: Bool = false,
            scripts: HostCommands.Scripts? = .bundled
        ) {
            directory = host.home.path
            var configuration = RemoteHosts.Configuration(key: host.key, declines: .memory(), creationGrace: creationGrace)
            configuration.roamingEnabled = { roaming }
            configuration.scripts = scripts
            configuration.hostDidConnect = { [connections] destination in connections.mutate { $0.append(destination) } }
            configuration.linkReady = { [readyHosts] destination in readyHosts.mutate { $0.append(destination) } }
            configuration.hostLost = { [lost] destination in lost.mutate { $0.append(destination) } }
            configuration.hostAnswered = { [answers] destination in answers.mutate { $0.append(destination) } }
            hosts = RemoteHosts(connections: host.connections, servers: host.servers, configuration: configuration)
        }

        func pane() -> Pane {
            Pane(projectPath: "box:\(directory)", projectID: UUID())
        }

        /// What the pane runs, after the waits that a login or an install
        /// cause.
        func ask(_ pane: Pane, prompts: Bool = true) async throws -> RemoteHost.Attachment {
            let host = try #require(hosts.host(of: pane))
            return try await host.attachment(for: pane.sessionName, pane: pane, directory: directory, prompts: prompts)
        }

        /// The link that the pane attaches over, and the folder when it
        /// makes its session.
        func attach(_ pane: Pane, prompts: Bool = true) async throws -> (link: RemoteServers.Link, create: String?) {
            let answer = try await ask(pane, prompts: prompts)
            guard case let .channel(link, create) = answer else {
                throw Unexpected(answer: answer)
            }
            return (link, create)
        }

        /// Waits until a view of the pane waits for its next try.
        func untilWaiting(_ pane: Pane) async throws {
            let deadline = Date().addingTimeInterval(20)
            while host.waiterCount(for: pane.sessionName) == 0, Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        /// The sweep of the app, for a lost pane with no driver: the value
        /// that its view's wait gets.
        func sweep(_ pane: Pane, answered: Bool = false) async throws -> Bool {
            let wait = Task { try await host.nextTry(for: pane.sessionName) }
            try await untilWaiting(pane)
            hosts.reconnect(["box"], answered: answered)
            return try await wait.value
        }

        struct Running {
            let session: PaneSession
            let host: RecordingPaneHost

            func type(_ text: String) {
                session.sendInput(Data(text.utf8))
            }

            func stop() {
                session.stop()
            }
        }

        /// What the pane's driver does: the session on the host's link, with
        /// no reconnect of its own.
        func start(_ pane: Pane, prompts: Bool = true) async throws -> Running {
            let (link, create) = try await attach(pane, prompts: prompts)
            var launch: PaneSession.Launch?
            if let create {
                launch = try #require(await hosts.createLaunch(link: link, directory: create)).launch
            }
            let host = RecordingPaneHost()
            let session = PaneSession(
                name: pane.sessionName, launch: launch, wantsForeground: true,
                host: host, endpoint: link
            )
            session.start()
            try await host.waitFor { $0.resets > 0 }
            // What the driver does at the session's first lead message.
            self.host.sessionAttached(pane.sessionName, pane: pane)
            return Running(session: session, host: host)
        }

        struct Unexpected: Error {
            var answer: RemoteHost.Attachment
        }
    }
}

extension RemoteHost.Attachment {
    var isEnded: Bool {
        if case .ended = self { true } else { false }
    }
}

extension RemoteHosts.DeclineStore {
    static func memory() -> Self {
        let box = LockedBox<[String]>([])
        return .init(read: { box.value }, write: { value in box.mutate { $0 = value } })
    }
}
