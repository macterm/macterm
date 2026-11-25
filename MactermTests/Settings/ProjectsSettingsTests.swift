import Foundation
@testable import Macterm
import Testing

/// Create Project of a layout file adds a remote project only when its folder
/// is on the host (0366), as New Remote Project does.
@MainActor
struct ProjectsSettingsTests {
    private func store() -> ProjectStore {
        let store = ProjectStore(writer: ModelWriter(connection: TestModel.connection()))
        store.autoAssignsColors = { false }
        return store
    }

    private func listing(path: String?, name: String? = "api") -> ProjectFileStore.Listing {
        ProjectFileStore.Listing(
            url: URL(fileURLWithPath: "/tmp/layouts/api.yaml"),
            declaredName: name,
            declaredPath: path,
            tabCount: 1,
            isInvalid: false
        )
    }

    @Test
    func a_refused_remote_path_adds_nothing() async {
        let projects = store()
        var asked: [String] = []
        let outcome = await ProjectsSettings.createProject(from: listing(path: "box:~/gone"), in: projects) {
            asked.append($0)
            return "Path ~/gone doesn't exist"
        }
        #expect(outcome == .refused("Path ~/gone doesn't exist"))
        #expect(asked == ["box:~/gone"])
        #expect(projects.projects.isEmpty)
    }

    @Test
    func a_checked_remote_path_is_added() async {
        let projects = store()
        let outcome = await ProjectsSettings.createProject(from: listing(path: "box:~/api"), in: projects) { _ in nil }
        guard case let .created(project) = outcome else {
            Issue.record("expected a project, got \(outcome)")
            return
        }
        #expect(project.name == "api")
        #expect(project.path == "box:~/api")
        #expect(projects.projects.map(\.id) == [project.id])
    }

    @Test
    func a_declared_name_with_a_slash_gets_a_hyphen() async {
        // The `name:` of a layout file is a recorded name, not one the user
        // typed here: it is changed, not refused (`ProjectStore.allowedName`).
        let projects = store()
        let outcome = await ProjectsSettings.createProject(
            from: listing(path: "box:~/api", name: "Work/api"),
            in: projects
        ) { _ in nil }
        guard case let .created(project) = outcome else {
            Issue.record("expected a project, got \(outcome)")
            return
        }
        #expect(project.name == "Work-api")
    }

    @Test
    func a_check_that_stops_adds_nothing() async {
        let projects = store()
        let outcome = await Task {
            await ProjectsSettings.createProject(from: listing(path: "box:~/api"), in: projects) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return nil
            }
        }.value
        #expect(outcome == .cancelled)
        #expect(projects.projects.isEmpty)
    }

    @Test
    func a_file_with_no_path_checks_nothing() async {
        let projects = store()
        var asked = false
        let outcome = await ProjectsSettings.createProject(from: listing(path: nil), in: projects) { _ in
            asked = true
            return nil
        }
        #expect(outcome == .noPath)
        #expect(!asked)
        #expect(projects.projects.isEmpty)
    }

    @Test
    func no_declared_name_takes_the_filename() async {
        let projects = store()
        let outcome = await ProjectsSettings.createProject(from: listing(path: "box:~/api", name: "  "), in: projects) { _ in nil }
        guard case let .created(project) = outcome else {
            Issue.record("expected a project, got \(outcome)")
            return
        }
        #expect(project.name == "api")
    }
}
