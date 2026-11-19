import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ModelShadow")

/// The shadow stage of design/010 §9 (step 3). `AppState` still owns the
/// model. After each save, this sends the server a copy of it
/// (`model.replace`), so that the server's model, its `model.json` and its
/// events run on real data before the cut-over. `mirror` follows the
/// server's events, and a DEBUG build compares it with what it sent and logs
/// a difference. A user sees nothing. Step 7 removes it.
@MainActor
final class ModelShadow {
    /// Debug and tip builds only. The unit-test host starts no server.
    nonisolated static var isEnabled: Bool {
        if SessionClient.liveBypass == .unitTestHost { return false }
        #if DEBUG
        return true
        #else
        return UpdateChannel.bundleDefault == .tip
        #endif
    }

    let mirror = ModelMirror()
    private let sessions: LocalSessions
    private weak var projectStore: ProjectStore?
    /// The newest model that waits to go. One request is out at a time, and
    /// a newer save replaces a model that did not go yet.
    private var waiting: MactermProtocol.ModelData?
    private var sending = false
    /// The server has a model that it can change.
    private var serverHasModel = false
    private var compare: Task<Void, Never>?
    /// The model that the server took last.
    private(set) var lastSent: MactermProtocol.ModelData?

    init(projectStore: ProjectStore, sessions: LocalSessions = .shared) {
        self.projectStore = projectStore
        self.sessions = sessions
    }

    func start() async {
        await sessions.setModelFeed { [weak self] item in self?.receive(item) }
    }

    /// Takes the app's state after a save. `workspaces` are the snapshots
    /// that the save wrote.
    func workspacesDidSave(_ workspaces: [ModelConversion.WorkspaceInput], activeProjectID: UUID?) {
        guard let projectStore else { return }
        waiting = ModelConversion.model(projects: projectStore.allRows, workspaces: workspaces, activeProjectID: activeProjectID)
        send()
    }

    private func receive(_ item: LocalSessions.ModelFeed) {
        switch item {
        case .connected:
            mirror.reset()
            serverHasModel = false
            Task { await subscribe() }
        case let .batch(batch):
            mirror.apply(batch)
        }
    }

    private func subscribe() async {
        do {
            let state = try await sessions.subscribe()
            mirror.install(state)
            serverHasModel = state.model != nil && !state.readonly
            if state.model == nil {
                logger.info("model shadow: the server has no model")
            } else if state.readonly {
                logger.warning("model shadow: the server's model is read-only")
            }
            send()
        } catch {
            logger.warning("model shadow: state.subscribe failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func send() {
        guard serverHasModel, !sending, let model = waiting else { return }
        waiting = nil
        sending = true
        Task {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                try await sessions.replaceModel(model)
                lastSent = model
                let micros = start.duration(to: clock.now) / .microseconds(1)
                logger.debug("model shadow: model.replace took \(Int(micros), privacy: .public) µs")
                check(model)
            } catch {
                logger.error("model shadow: model.replace failed: \(String(describing: error), privacy: .public)")
            }
            sending = false
            send()
        }
    }

    /// Logs where the mirror and the model that the server took differ. The
    /// batch and the reply come on different paths, so the check waits for
    /// the mirror up to one second before it logs.
    private func check(_ sent: MactermProtocol.ModelData) {
        #if DEBUG
        compare?.cancel()
        compare = Task { [mirror] in
            var differences: [String] = []
            for _ in 0 ..< 10 {
                guard let data = mirror.data else { return }
                differences = ModelConversion.differences(mirror: data, sent: sent)
                if differences.isEmpty { return }
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            logger.error("model shadow: the mirror differs from the app: \(differences.joined(separator: ", "), privacy: .public)")
        }
        #endif
    }
}
