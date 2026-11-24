import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PaneSession")

/// The size of the pane's surface, in cells and pixels.
struct PaneGrid: Equatable {
    var cols: UInt16
    var rows: UInt16
    var widthPx: UInt32 = 0
    var heightPx: UInt32 = 0
}

/// What a `PaneSession` drives: the surface that shows the pane. The
/// callbacks come from the session's tasks, not from the main actor.
protocol PaneSessionHost: AnyObject, Sendable {
    /// Bytes for the terminal (output, or a snapshot).
    func paneFeed(_ data: Data)
    /// The surface's size now.
    func paneGrid() -> PaneGrid
    /// A snapshot of the pane starts or ends.
    func paneSnapshot(started: Bool)
    /// The session's pid, its shell's pid and its pty: at each attach.
    func paneState(_ state: MactermProtocol.State)
    /// The pty's foreground, when the session was asked for it: at an
    /// attach, and before the output that follows a change.
    func paneForeground(_ foreground: MactermProtocol.Foreground)
    /// An OSC 0/2 title. The session coalesces titles, and sends none from
    /// a snapshot: the current title comes after the foreground at an attach.
    func paneTitle(_ title: Data)
    /// The shell's folder (OSC 7), as a URL.
    func paneCwd(_ url: Data)
    /// An OSC 133 mark that the session parsed.
    func paneMark(_ mark: MactermProtocol.Mark)
    /// The session's run status: at each change, and at `hello` while it is
    /// not idle.
    func paneStatus(_ status: MactermProtocol.Status)
    /// The pty's line modes, when the session was asked for them.
    func paneTtyMode(_ mode: MactermProtocol.TtyMode)
    /// The session's attention flags: at an attach when one is set, and at
    /// each change (design/004 §6). All clear when the channel ends.
    func paneAttention(_ flags: MactermProtocol.Attention)
    /// The session says whether this client leads: its size is the pty's.
    /// Nil when the channel ended: the next attach tells again.
    func paneLead(_ leader: Bool?)
    /// The shell exited. The session ended.
    func paneExited(code: UInt8?, signal: UInt8?)
    /// The channel ended with no exit. The session asks its endpoint for a
    /// connection again.
    func paneLinkLost()
    /// Input that the channel could not take (the link is down). The host
    /// keeps it for the next attach: a key never goes away with no sign.
    func paneInputUndelivered(_ data: Data)
    /// The endpoint has no connection to give, or the channel failed too
    /// often. The session stops. The pane has nothing to show.
    func paneGone()
}

/// Where a surface sends what the user does: keys, pastes, replies, the size
/// and the lead. A `PaneSession`, or the driver of a remote pane, which
/// answers some keys itself while the pane waits.
protocol PaneInputRoute: AnyObject, Sendable {
    func sendInput(_ data: Data)
    func claim(grid: PaneGrid?)
    func sendSize(_ grid: PaneGrid?)
    /// The user saw the pane: the session clears its attention flags.
    func seen()
}

extension PaneInputRoute {
    func seen() {}
}

extension PaneSessionHost {
    func paneSnapshot(started _: Bool) {}
    func paneState(_: MactermProtocol.State) {}
    func paneTitle(_: Data) {}
    func paneCwd(_: Data) {}
    func paneMark(_: MactermProtocol.Mark) {}
    func paneStatus(_: MactermProtocol.Status) {}
    func paneAttention(_: MactermProtocol.Attention) {}
    func paneLead(_: Bool?) {}
    func paneLinkLost() {}
    func paneInputUndelivered(_: Data) {}
}

/// One surface's view channel on a pane's session, local or on a host: it
/// makes the session when a `launch` is given, opens a channel, attaches,
/// and feeds the host from the channel. A pane's `PaneLink` makes the
/// session once (`create`) and gives its views no launch. Input, claims
/// and sizes go back on the same channel, in order, from a queue of its
/// own, so a stalled server never blocks the caller.
///
/// One rule for a lost link: a channel that ends with no exit reports
/// `paneLinkLost`, and the session asks its endpoint for a connection again,
/// attaches again, and asks to resume from the last output byte that the
/// surface got (design/003 §7). The session then sends only the bytes after
/// it (`resumed`), and the screen and the scrollback stay. When the session
/// cannot resume (another epoch, or its ring lost the bytes), its snapshot
/// draws the pane over a cleared screen. The endpoint decides if there is a next connection
/// (`ServerEndpoint`): the local server tries for a few seconds, and a
/// host's link has none after it ended. An endpoint with no connection to
/// give ends the session with `paneGone`.
final class PaneSession: PaneInputRoute, @unchecked Sendable {
    /// What a new session runs: the launch that libghostty resolved for the
    /// pane (`ghostty_launch_resolve`), or nothing for a remote pane, whose
    /// session runs the user's login shell on the host.
    struct Launch: Equatable {
        var cwd: String?
        var argv: [String]?
        var env: [String]
    }

    /// Where a client can resume a session's output: the `epoch` of the
    /// session's `hello` and the offset after the last output byte that the
    /// surface shows.
    struct ResumePoint: Equatable {
        var epoch: UInt64
        var offset: UInt64
    }

    /// Clears the screen, the scrollback and the cursor.
    static let resetScreen = Data("\u{1B}[0m\u{1B}[3J\u{1B}[2J\u{1B}[H".utf8)

    /// A channel that fails or ends at once counts as a failed try. After
    /// more than this many in a row the pane is gone, so a server that drops
    /// each channel does not make a tight loop.
    private static let channelTries = 12
    private static let channelWait: Duration = .milliseconds(500)
    /// The limit of new attaches on one channel for a grid that changes
    /// before its snapshot. After the limit, the snapshot is drawn.
    static let attachAgainLimit = 3
    /// The longest time that `heldInput` waits for the shell after an
    /// attach. A shell with no OSC 133 marks (a plain `sh`) gets the input
    /// after this time.
    static let shellStartWait: Duration = .seconds(2)

    let name: String
    private let host: any PaneSessionHost
    private let endpoint: any ServerEndpoint
    private let launch: Launch?
    private let wantsForeground: Bool
    private let wantsTty: Bool
    private let startWait: Duration

    private let lock = NSLock()
    private var channel: PaneChannel?
    /// Where the next attach asks to resume. Nil while the surface shows
    /// no screen of a known offset: before the first output, and from the
    /// start of a snapshot to its draw.
    private var resume: ResumePoint?
    private var task: Task<Void, Never>?
    private var stopped = false
    /// Input that came before the first channel. Over 1 MiB the rest is
    /// dropped. At the first attach it becomes `heldInput`.
    private var pendingInput = Data()
    private var attached = false
    /// Input from before the first attach: a layout's `run:` (libghostty's
    /// `initial_input`) and keys typed while the pane connects. The pty
    /// echoes input at once, so input sent at the attach of a new shell
    /// shows before the login lines and the prompt, and again after them.
    /// It therefore waits until the shell reads input: an OSC 133 mark after
    /// the prompt, or a run, which the session parses (`events.zig`). With
    /// no sign it goes after `startWait`. It goes once. Input after the
    /// attach (terminal replies, keys) does not wait: a shell can query the
    /// terminal before its first prompt.
    private var heldInput = Data()
    private var holdTimer: Task<Void, Never>?
    /// A claim that came before the first attach.
    private var claimPending = false
    private let output = DispatchQueue(label: "PaneSession.input")

    init(
        name: String,
        launch: Launch?,
        wantsForeground: Bool,
        wantsTty: Bool = false,
        startWait: Duration = PaneSession.shellStartWait,
        resume: ResumePoint? = nil,
        host: any PaneSessionHost,
        endpoint: any ServerEndpoint
    ) {
        self.name = name
        self.resume = resume
        self.launch = launch
        self.wantsForeground = wantsForeground
        self.wantsTty = wantsTty
        self.startWait = startWait
        self.host = host
        self.endpoint = endpoint
    }

    /// Starts the session and the reading. Call it once.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil, !stopped else { return }
        task = Task { [self] in await run() }
    }

    /// Ends the reading and the channel. The session keeps running.
    func stop() {
        lock.lock()
        stopped = true
        let task = task
        let channel = channel
        self.channel = nil
        let holdTimer = holdTimer
        self.holdTimer = nil
        lock.unlock()
        task?.cancel()
        holdTimer?.cancel()
        if let channel { Task { await channel.close() } }
    }

    /// Stops the session and waits until its reading ended. Then no byte
    /// goes to the host any more, and `resumePoint` is the offset of the
    /// last byte that it got. A driver that starts a new session for the
    /// same pane takes the point from here, not from `stop()`.
    func finish() async -> ResumePoint? {
        stop()
        let task = lock.withLock { task }
        await task?.value
        return resumePoint
    }

    // MARK: - Input

    /// Keys, pastes and terminal replies. Input that the channel cannot take
    /// goes back to the host (`paneInputUndelivered`). Input that waits for
    /// the first attach or for the shell is returned by `takePendingInput`.
    func sendInput(_ data: Data) {
        lock.lock()
        if !attached {
            if pendingInput.count + data.count <= 1 << 20 { pendingInput.append(data) }
            lock.unlock()
            return
        }
        lock.unlock()
        guard let channel = currentChannel() else {
            host.paneInputUndelivered(data)
            // A key in a channel that ended reports it again.
            host.paneLinkLost()
            return
        }
        output.async { [host] in
            do { try channel.sendInput(data) } catch ProtocolFrame.FrameError.tooLarge {
                // A paste over the frame limit never fits: the link is fine.
                logger.info("pane \(self.name, privacy: .public): input too large")
            } catch {
                logger.info("pane \(self.name, privacy: .public): input not sent: \(String(describing: error), privacy: .public)")
                host.paneInputUndelivered(data)
                host.paneLinkLost()
            }
        }
    }

    /// The input that never reached a channel. Call it after `stop()`.
    func takePendingInput() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let kept = heldInput + pendingInput
        heldInput = Data()
        pendingInput = Data()
        return kept
    }

    /// Takes the lead: this client's size becomes the pty's.
    func claim(grid: PaneGrid?) {
        lock.lock()
        if !attached {
            claimPending = true
            lock.unlock()
            return
        }
        lock.unlock()
        send { channel in
            try channel.send(MactermProtocol.Claim())
        }
        sendSize(grid)
    }

    /// The user saw the pane: the session clears its attention flags and
    /// sends them again to every client.
    func seen() {
        send { try $0.send(MactermProtocol.Seen()) }
    }

    /// Tells the session the surface's size. Only the leader's size reaches
    /// the pty.
    func sendSize(_ known: PaneGrid?) {
        let grid = known ?? host.paneGrid()
        let resize = MactermProtocol.Resize(
            cols: grid.cols, rows: grid.rows,
            xpixel: Self.clamp(grid.widthPx), ypixel: Self.clamp(grid.heightPx)
        )
        send { try $0.send(resize) }
    }

    private func send(_ body: @escaping @Sendable (PaneChannel) throws -> Void) {
        guard let channel = currentChannel() else { return }
        output.async {
            do { try body(channel) } catch {
                logger.info("pane \(self.name, privacy: .public): send failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func currentChannel() -> PaneChannel? {
        lock.lock()
        defer { lock.unlock() }
        return channel
    }

    private static func clamp(_ value: UInt32) -> UInt16 {
        UInt16(min(value, UInt32(UInt16.max)))
    }

    // MARK: - The reading

    private func run() async {
        var firstAttach = true
        var reconnected = false
        var tries = 0
        while !Task.isCancelled {
            let channels: any PaneChannelOpener
            do {
                channels = try await endpoint.paneChannels()
            } catch {
                if !(error is CancellationError), !Task.isCancelled {
                    logger.info("pane \(self.name, privacy: .public): no connection: \(String(describing: error), privacy: .public)")
                    host.paneGone()
                }
                return
            }
            // After a failed try, wait before the next one. The endpoint
            // answers first: one with no next connection ends the pane now.
            if tries > 0 { try? await Task.sleep(for: Self.channelWait) }
            if Task.isCancelled { return }
            do {
                // Only the first attach makes the session. A session that is
                // gone later ended: the server ends a session whose shell
                // exited, and a new shell here would hide that.
                if firstAttach, let launch {
                    // On the relay's link when the channel goes there, so
                    // that the create and the channel are one connection.
                    let link = try await (channels as? any ServerLink) ?? endpoint.connection()
                    try await createSession(on: link, launch)
                }
                let channel = try await channels.openChannel(session: name)
                guard install(channel) else {
                    await channel.close()
                    return
                }
                let grid = host.paneGrid()
                let resuming = matchingResumePoint(channel)
                try sendAttach(channel, grid, resume: resuming)
                // The offset that the screen shows. Only a cleared screen
                // is at 0: a session with no output sends no snapshot.
                var shown = resuming?.offset
                if firstAttach {
                    // A pane that asks to resume keeps its screen. Its
                    // reset waits for a snapshot.
                    if resuming == nil {
                        host.paneFeed(Self.resetScreen)
                        shown = 0
                    }
                    firstAttach = false
                }
                if markAttached(channel) { claim(grid: nil) }
                let started = Date()
                if await read(channel, reconnected: reconnected || resuming != nil, shows: shown, attachedAt: grid) {
                    return
                }
                reconnected = true
                // A channel that ends at once counts as a failed try.
                tries = Date().timeIntervalSince(started) < 2 ? tries + 1 : 0
                uninstall()
                channelEnded()
                host.paneLinkLost()
            } catch is CancellationError {
                return
            } catch let ProtocolControlError.errorResponse(info) where info.errorCode == .notFound && !firstAttach {
                host.paneExited(code: nil, signal: nil)
                return
            } catch is SessionSocket.Gone where !firstAttach {
                // The session's socket has no listener: the session ended
                // with no exit status (killed, or crashed), as a relay's
                // channel ends with an empty `exit`.
                host.paneExited(code: nil, signal: nil)
                return
            } catch {
                logger.info("pane \(self.name, privacy: .public): \(String(describing: error), privacy: .public)")
                if uninstall() { channelEnded() }
                tries += 1
            }
            if tries > Self.channelTries {
                host.paneGone()
                return
            }
        }
    }

    private func sendAttach(_ channel: PaneChannel, _ grid: PaneGrid, resume: ResumePoint? = nil) throws {
        try channel.send(MactermProtocol.Attach(
            cols: grid.cols, rows: grid.rows,
            xpixel: Self.clamp(grid.widthPx), ypixel: Self.clamp(grid.heightPx),
            foreground: wantsForeground,
            tty: wantsTty,
            resumeEpoch: resume?.epoch,
            resumeOffset: resume?.offset
        ))
    }

    /// Where the surface can resume now. A driver that starts a new session
    /// for the same pane gives it to that session.
    var resumePoint: ResumePoint? {
        lock.withLock { resume }
    }

    /// The point to resume on `channel`: only for the epoch of the session
    /// that the surface shows. Another epoch is another session process,
    /// whose offsets count from 0.
    private func matchingResumePoint(_ channel: PaneChannel) -> ResumePoint? {
        lock.withLock {
            guard let point = resume, point.epoch == channel.epoch else { return nil }
            return point
        }
    }

    /// The reading of `channel` ended: the next attach resumes after
    /// `offset`, the last output byte that the surface got. Nil when the
    /// screen shows no known offset: the next attach gets a snapshot.
    private func keepResumePoint(_ channel: PaneChannel, _ offset: UInt64?) {
        lock.withLock {
            resume = channel.epoch.flatMap { epoch in offset.map { ResumePoint(epoch: epoch, offset: $0) } }
        }
    }

    /// Reads events until the channel ends. True when the session ended (an
    /// exit) or the reading was cancelled.
    ///
    /// The snapshot of an attach is laid out at the attach's grid, with the
    /// cursor at an absolute row. Drawn at another grid, it puts the cursor
    /// on the wrong line, and the shell's redraw writes over lines (0430).
    /// So it is held until its end. When the grid changed while this client
    /// leads, it is dropped with the output after it, and the client attaches
    /// again at the new grid. The second snapshot has that output.
    ///
    /// It counts the output offset that the surface shows: a drawn
    /// snapshot's `offset` or a `resumed` offset, and the output bytes after
    /// it, from `start`, the offset that the screen shows at the attach. The
    /// relay's skip-ahead drops output and sends a snapshot, which
    /// sets the count again. When the channel ends, the count is the next
    /// attach's resume point.
    private func read(_ channel: PaneChannel, reconnected: Bool, shows start: UInt64?, attachedAt grid: PaneGrid) async -> Bool {
        var needsReset = reconnected
        // A resume's `resumed` comes before any output, and repeats the
        // offset. A channel that ends before it leaves the screen as it was.
        var offset = start
        // The offset of the snapshot that is in progress.
        var snapshotOffset: UInt64?
        defer { keepResumePoint(channel, offset) }
        var leads = false
        // The grid of the last attach, until its snapshot or the first
        // output: an attach to a session with no output gets no snapshot.
        var attachGrid: PaneGrid? = grid
        var attachesAgain = 0
        // The bytes of the snapshot that is in progress.
        var held: Data?
        var dropsOutput = false
        for await event in channel.events {
            switch event {
            case let .output(data):
                if held != nil {
                    held?.append(data)
                } else if !dropsOutput {
                    attachGrid = nil
                    offset = offset.map { $0 + UInt64(data.count) }
                    host.paneFeed(data)
                }
            case let .snapshotStart(start):
                // The first snapshot comes over the cleared screen. One after
                // a lost link comes over the old screen: clear it first.
                if needsReset {
                    host.paneFeed(Self.resetScreen)
                    needsReset = false
                }
                dropsOutput = false
                held = Data()
                // The screen changes: no offset until the snapshot is drawn.
                offset = nil
                snapshotOffset = start.offset
            case .snapshotEnd:
                let bytes = held ?? Data()
                held = nil
                let now = host.paneGrid()
                // The server ignores an attach of size 0.
                if leads, let laidOut = attachGrid, laidOut.cols != now.cols || laidOut.rows != now.rows,
                   now.cols > 0, now.rows > 0, attachesAgain < Self.attachAgainLimit
                {
                    attachesAgain += 1
                    attachGrid = now
                    dropsOutput = true
                    let change = "\(laidOut.cols)x\(laidOut.rows) to \(now.cols)x\(now.rows)"
                    logger.info("pane \(self.name, privacy: .public): grid \(change, privacy: .public), attach again")
                    // On the queue of the sizes, so that it goes after a
                    // resize that waits there.
                    send { [self] in try sendAttach($0, now) }
                    continue
                }
                attachGrid = nil
                host.paneSnapshot(started: true)
                if !bytes.isEmpty { host.paneFeed(bytes) }
                host.paneSnapshot(started: false)
                offset = snapshotOffset
            case let .lead(leader):
                leads = leader
                // A client that starts to lead sends its size.
                if leader { sendSize(nil) }
                host.paneLead(leader)
            case let .foreground(foreground):
                host.paneForeground(foreground)
            case let .ttyMode(mode):
                host.paneTtyMode(mode)
            case let .attention(flags):
                host.paneAttention(flags)
            case let .exit(exit):
                host.paneExited(code: exit.code, signal: exit.signal)
                return true
            case let .mark(mark):
                // After the prompt mark the shell may not own the tty yet,
                // and the pty would echo the input before the prompt.
                if mark.kind != .prompt { releaseHeldInput() }
                host.paneMark(mark)
            case let .status(status):
                // A program runs and reads its input.
                releaseHeldInput()
                host.paneStatus(status)
            case let .state(state):
                host.paneState(state)
            case let .title(title):
                host.paneTitle(title)
            case let .cwd(url):
                host.paneCwd(url)
            case let .resumed(resumed):
                // The bytes after the surface's offset follow: the screen
                // and the scrollback stay.
                needsReset = false
                offset = resumed.offset
            case .other:
                break
            }
        }
        return Task.isCancelled
    }

    /// Makes the session, or finds it. The server ends a session whose shell
    /// exited while no client read its status and makes a new one
    /// (`replace_exited`), as `zmx attach` did in v1.
    private func createSession(on connection: any ServerLink, _ launch: Launch) async throws {
        try await Self.create(on: connection, name: name, launch: launch, grid: host.paneGrid())
    }

    /// Makes the session `name` at the size `grid`, or finds it. A pane's
    /// `PaneLink` calls it once for the pane, before any surface opens a
    /// channel, so that two windows make one session.
    static func create(on connection: any ServerLink, name: String, launch: Launch, grid: PaneGrid) async throws {
        let args = MactermProtocol.SessionCreate.Args(
            id: name,
            cwd: launch.cwd.map { ProtocolBin(Data($0.utf8)) },
            command: launch.argv.map { $0.map { ProtocolBin(Data($0.utf8)) } },
            cols: grid.cols,
            rows: grid.rows,
            env: launch.env.map { ProtocolBin(Data($0.utf8)) },
            replaceExited: true
        )
        _ = try await connection.call(MactermProtocol.SessionCreate.self, args)
    }

    /// The channel ended. The lead and the flags were this channel's: the
    /// next attach tells them again. The session sends its flags at an
    /// attach only when one is set, so a copy kept here could stay wrong.
    private func channelEnded() {
        host.paneLead(nil)
        host.paneAttention(MactermProtocol.Attention())
    }

    private func install(_ channel: PaneChannel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        self.channel = channel
        return true
    }

    /// True when a channel was installed.
    @discardableResult
    private func uninstall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { channel = nil }
        return channel != nil
    }

    /// An attach went out. The input from before the first attach becomes
    /// `heldInput`. True when a claim waited too.
    private func markAttached(_ channel: PaneChannel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !attached {
            heldInput = pendingInput
            pendingInput = Data()
        }
        attached = true
        if !heldInput.isEmpty {
            // The wait starts again at each attach: the input went nowhere.
            holdTimer?.cancel()
            holdTimer = Task { [self, startWait] in
                try? await Task.sleep(for: startWait)
                guard !Task.isCancelled else { return }
                releaseHeldInput()
            }
        }
        defer { claimPending = false }
        return claimPending
    }

    /// Sends `heldInput`, once. A stopped session sends nothing, and
    /// `takePendingInput` gives the input back.
    private func releaseHeldInput() {
        lock.lock()
        defer { lock.unlock() }
        guard !heldInput.isEmpty, !stopped, let channel else { return }
        holdTimer?.cancel()
        holdTimer = nil
        let held = heldInput
        heldInput = Data()
        output.async { [host] in
            do { try channel.sendInput(held) } catch ProtocolFrame.FrameError.tooLarge {
                logger.info("pane \(self.name, privacy: .public): held input too large")
            } catch {
                logger.info("pane \(self.name, privacy: .public): held input not sent: \(String(describing: error), privacy: .public)")
                host.paneInputUndelivered(held)
            }
        }
    }
}
