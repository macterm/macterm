import Foundation
@testable import Macterm
import Testing

/// The app's link to the model (design/010 §4): a request returns after the
/// mirror has its change, a refusal and no server are errors, and a batch of
/// another client reaches the mirror in a main-queue turn.
@MainActor
struct ModelConnectionTests {
    private func project(_ id: String) -> MactermProtocol.ProjectCreate.Args {
        .init(id: id, name: "P \(id)", path: "/tmp")
    }

    @Test
    func a_request_returns_after_the_mirror_has_its_change() throws {
        let connection = TestModel.connection()
        defer { connection.close() }
        let id = UUID()
        try connection.send(MactermProtocol.ProjectCreate.self, project(id.uuidString))
        // No main-queue turn ran: the reply came after the batch.
        #expect(connection.mirror.project(id)?.name == "P \(id.uuidString)")
    }

    @Test
    func a_refused_request_throws_and_changes_nothing() throws {
        let connection = TestModel.connection()
        defer { connection.close() }
        let id = UUID().uuidString
        try connection.send(MactermProtocol.ProjectCreate.self, project(id))
        let before = connection.mirror.projects
        #expect(throws: ModelRequestError.self) {
            try connection.send(MactermProtocol.ProjectCreate.self, project(id))
        }
        do {
            try connection.send(MactermProtocol.ProjectCreate.self, project(id))
        } catch let ModelRequestError.refused(code, _) {
            #expect(code == .duplicateId)
        }
        #expect(connection.mirror.projects == before)
    }

    @Test
    func a_closed_connection_is_unavailable() {
        let connection = TestModel.connection()
        connection.close()
        #expect(throws: ModelRequestError.unavailable) {
            try connection.send(MactermProtocol.ProjectCreate.self, project(UUID().uuidString))
        }
    }

    @Test
    func a_batch_of_another_client_reaches_the_mirror() async throws {
        let connection = TestModel.connection()
        defer { connection.close() }
        // A second client of the same server: the CLI, for example.
        let other = ModelConnection(server: connection.server)
        try other.connectNow()
        defer { other.close() }
        let id = UUID()
        try other.send(MactermProtocol.ProjectCreate.self, project(id.uuidString))
        let deadline = ContinuousClock.now + .seconds(5)
        while connection.mirror.project(id) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(connection.mirror.project(id) != nil)
    }

    @Test
    func a_change_of_the_projects_calls_the_hook_once_for_each_batch() throws {
        let connection = TestModel.connection()
        defer { connection.close() }
        var calls = 0
        connection.mirror.onProjectsChanged = { calls += 1 }
        let id = UUID().uuidString
        try connection.send(MactermProtocol.ProjectCreate.self, project(id))
        try connection.send(MactermProtocol.ProjectSet.self, .init(id: id, name: "Renamed"))
        try connection.send(MactermProtocol.ProjectRemove.self, .init(id: id))
        #expect(calls == 3)
    }
}
