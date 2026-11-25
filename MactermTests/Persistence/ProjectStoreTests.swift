import Foundation
@testable import Macterm
import Testing

/// The projects of the sidebar tree: the mirror's tree projects, and their
/// requests to a real server (`TestModel`). v1's `projects.json` is read
/// only by the import (`ProjectStore.readV1`).
@MainActor
struct ProjectStoreTests {
    private func makeStore() -> ProjectStore {
        TestModel.projectStore(TestModel.appState())
    }

    private func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-\(label)-\(UUID().uuidString).json")
    }

    /// The rows of a v1 `projects.json` that holds `data`.
    private func readV1(_ data: Data) throws -> (rows: [Project], failed: Bool) {
        let url = tempURL("v1")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return ProjectStore.readV1(fileURL: url)
    }

    @Test
    func find_or_create_reuses_canonical_local_path() throws {
        let store = makeStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-\(UUID().uuidString)", isDirectory: true)
            .path
        let existing = try #require(store.add(Project(name: "existing", path: base + "/./", sortOrder: 0)))

        let project = try #require(store.findOrCreate(name: "duplicate", path: base))

        #expect(project.id == existing.id)
        #expect(project.name == "existing")
        #expect(store.projects.count == 1)
    }

    @Test
    func create_with_a_parent_goes_at_the_end_of_its_projects() throws {
        let store = makeStore()
        let parent = try #require(store.create(name: "parent", path: "/tmp/parent"))
        let first = try #require(store.create(name: "first", path: "/tmp/first", parent: parent.id))
        let second = try #require(store.create(name: "second", path: "/tmp/second", parent: parent.id))
        #expect(store.children(of: parent.id).map(\.id) == [first.id, second.id])
        #expect(store.create(name: "lost", path: "/tmp/lost", parent: UUID())?.parent == nil, "an unknown parent is the top level")
    }

    /// The offset counts the rows before the move, as a drop slot does.
    @Test
    func move_at_an_offset_puts_the_project_at_that_slot() {
        let store = makeStore()
        let a = store.create(name: "a", path: "/tmp/a")
        let b = store.create(name: "b", path: "/tmp/b")
        let c = store.create(name: "c", path: "/tmp/c")
        let parent = store.create(name: "parent", path: "/tmp/parent")
        let inner = store.create(name: "inner", path: "/tmp/inner", parent: parent.id)

        // Down among its own rows: the slot before c.
        #expect(store.move(a.id, into: nil, at: 2))
        #expect(store.children(of: nil).map(\.id) == [b.id, a.id, c.id, parent.id])
        // Up: the first slot.
        #expect(store.move(c.id, into: nil, at: 0))
        #expect(store.children(of: nil).map(\.id) == [c.id, b.id, a.id, parent.id])
        // Into another project, before its first row.
        #expect(store.move(b.id, into: parent.id, at: 0))
        #expect(store.children(of: parent.id).map(\.id) == [b.id, inner.id])
        #expect(store.children(of: nil).map(\.id) == [c.id, a.id, parent.id])
        // An offset past the end is the end.
        #expect(store.move(a.id, into: parent.id, at: 99))
        #expect(store.children(of: parent.id).map(\.id) == [b.id, inner.id, a.id])
        // Its own slot, or the slot after it: no change.
        #expect(store.move(b.id, into: parent.id, at: 0))
        #expect(store.move(b.id, into: parent.id, at: 1))
        #expect(store.children(of: parent.id).map(\.id) == [b.id, inner.id, a.id])
        // A negative offset is the first slot.
        #expect(store.move(a.id, into: parent.id, at: -3))
        #expect(store.children(of: parent.id).map(\.id) == [a.id, b.id, inner.id])
        // Never into itself or a project inside it, and no change of order.
        let topLevel = store.children(of: nil).map(\.id)
        #expect(!store.move(parent.id, into: inner.id, at: 0))
        #expect(store.row(parent.id)?.parent == nil)
        #expect(store.children(of: nil).map(\.id) == topLevel)
    }

    @Test
    func create_tags_a_new_project_only_when_auto_assign_is_on() throws {
        let store = makeStore()
        // Default (preference off): a new project carries no tag.
        #expect(store.create(name: "plain", path: "/tmp/a")?.color == nil)

        store.autoAssignsColors = { true }
        let first = try #require(store.create(name: "auto", path: "/tmp/b"))
        let second = try #require(store.create(name: "auto2", path: "/tmp/c"))

        #expect(first.color != nil)
        #expect(second.color != nil)
        // Distinct: the second sees the first's tag as already used.
        #expect(first.color != second.color)
        // The untagged one stays untagged: the setting is read at creation
        // only, never applied to older projects.
        #expect(store.projects.first?.color == nil)
    }

    @Test
    func set_color_tags_untags_and_persists_across_a_relaunch() throws {
        let state = TestModel.appState()
        let store = TestModel.projectStore(state)
        let project = try #require(store.create(name: "tagged", path: "/tmp"))

        store.setColor(id: project.id, to: .blue)
        #expect(store.projects.first?.color == .blue)
        // The server has it: a relaunch on the same server sees it.
        let gui = GUIStateStore(fileURL: TestModel.folder().appending(path: "gui-state.json"))
        #expect(TestModel.projectStore(TestModel.relaunch(state, guiStateStore: gui)).projects.first?.color == .blue)

        store.setColor(id: project.id, to: nil)
        #expect(store.projects.first?.color == nil)
        #expect(store.projects.first?.colorName == nil)
    }

    @Test
    func create_always_appends_even_for_a_matching_path() throws {
        // `create` never dedups, so the same directory can back several
        // independent projects.
        let store = makeStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-\(UUID().uuidString)", isDirectory: true)
            .path
        let first = try #require(store.create(name: "one", path: base))
        let second = try #require(store.create(name: "two", path: base + "/./"))

        #expect(first.id != second.id)
        #expect(store.projects.count == 2)
        // Both normalize to the same canonical path: distinct projects, one dir.
        #expect(store.projects.map(\.path) == [first.path, first.path])
        #expect(store.projects.map(\.name) == ["one", "two"])
    }

    @Test
    func create_disambiguates_the_pinned_workspaces_name() {
        // Every creation path funnels here, and most name a project after its
        // folder: a name nobody chose, so it is suffixed rather than refused.
        let store = makeStore()
        #expect(store.create(name: "Pinned", path: "/tmp/a")?.name == "Pinned 2")
        #expect(store.create(name: "pinned", path: "/tmp/b")?.name == "pinned 2")
        #expect(store.findOrCreate(name: "PINNED", path: "/tmp/c")?.name == "PINNED 2")
        // Only the name itself is reserved.
        #expect(store.create(name: "Pinned Tabs", path: "/tmp/d")?.name == "Pinned Tabs")
        #expect(store.create(name: "Pinned 2", path: "/tmp/e")?.name == "Pinned 2")
        #expect(store.projects.map(\.name) == ["Pinned 2", "pinned 2", "PINNED 2", "Pinned Tabs", "Pinned 2"])
    }

    @Test
    func rename_refuses_the_pinned_workspaces_name() throws {
        let store = makeStore()
        let project = try #require(store.create(name: "alpha", path: "/tmp"))

        store.rename(id: project.id, to: "Pinned")
        store.rename(id: project.id, to: " pinned ")
        #expect(store.projects.first?.name == "alpha")

        store.rename(id: project.id, to: "Pinned Tabs")
        #expect(store.projects.first?.name == "Pinned Tabs")
    }

    @Test
    func rename_refuses_a_slash() throws {
        let store = makeStore()
        let project = try #require(store.create(name: "alpha", path: "/tmp"))
        store.rename(id: project.id, to: "Work/api")
        #expect(store.projects.first?.name == "alpha")
    }

    @Test
    func create_changes_each_slash_to_a_hyphen() {
        // A name nobody typed (the `name:` of a layout file) is changed, not
        // refused, as a reserved name is.
        let store = makeStore()
        #expect(store.create(name: "Work/api/lib", path: "/tmp/a")?.name == "Work-api-lib")
        #expect(store.create(name: "Pinned/", path: "/tmp/b")?.name == "Pinned-")
        #expect(store.create(name: "api", path: "/tmp/c")?.name == "api")
    }

    @Test
    func a_v1_name_with_a_slash_still_reads() throws {
        // Names from before the rule stay as they are in the file. The
        // import changes them (`ModelConversion.namesWithoutSlash`).
        let id = UUID()
        let v1 = try readV1(Data("""
        [{"createdAt": 0, "id": "\(id)", "name": "Work/api", "path": "/tmp", "sortOrder": 0}]
        """.utf8))
        #expect(!v1.failed)
        #expect(v1.rows.map(\.name) == ["Work/api"])
        #expect(v1.rows.first?.id == id)
    }

    @Test
    func find_or_create_reuses_matching_remote_path() throws {
        let store = makeStore()
        let existing = try #require(store.add(Project(name: "api", path: "devbox:~/dev/api", sortOrder: 0)))

        let project = try #require(store.findOrCreate(name: "duplicate", path: "devbox:~/dev/api"))

        #expect(project.id == existing.id)
        #expect(project.name == "api")
        #expect(store.projects.count == 1)
    }

    /// The hidden projects of the model are not projects of the tree.
    @Test
    func the_hidden_projects_are_not_in_the_list() throws {
        let state = TestModel.appState()
        let store = TestModel.projectStore(state)
        let project = try #require(store.create(name: "a", path: "/tmp/a"))
        #expect(state.ensurePinnedProject() != nil)
        #expect(state.ensureScratchProject() != nil)
        #expect(state.model.projects.count == 3)
        #expect(store.projects.map(\.id) == [project.id])
        #expect(store.children(of: nil).map(\.id) == [project.id])
        let pinned = try #require(state.pinnedProjectID)
        #expect(store.row(pinned) == nil)
        #expect(!store.move(project.id, into: pinned), "a hidden project is no place for a project")
    }

    // MARK: - Mutators

    @Test
    func remove_drops_the_project() throws {
        let state = TestModel.appState()
        let store = TestModel.projectStore(state)
        let a = try #require(store.add(Project(name: "a", path: "/tmp/a", sortOrder: 0)))
        let b = try #require(store.add(Project(name: "b", path: "/tmp/b", sortOrder: 1)))
        state.removeProject(a.id, store: store)
        #expect(store.projects.map(\.id) == [b.id])
    }

    @Test
    func rename_changes_name_but_not_identity_or_path() throws {
        let store = makeStore()
        let p = try #require(store.add(Project(name: "old", path: "/tmp/x", sortOrder: 0)))
        store.rename(id: p.id, to: "new")
        let updated = store.projects.first { $0.id == p.id }
        #expect(updated?.name == "new")
        #expect(updated?.path == "/tmp/x")
    }

    @Test
    func setPath_updates_the_path() throws {
        let store = makeStore()
        let p = try #require(store.add(Project(name: "x", path: "/tmp/before", sortOrder: 0)))
        store.setPath(id: p.id, to: "/tmp/after")
        #expect(store.projects.first { $0.id == p.id }?.path == "/tmp/after")
    }

    @Test
    func reorder_reindexes_sortOrder() throws {
        let store = makeStore()
        let a = try #require(store.add(Project(name: "a", path: "/tmp/a", sortOrder: 0)))
        let b = try #require(store.add(Project(name: "b", path: "/tmp/b", sortOrder: 1)))
        let c = try #require(store.add(Project(name: "c", path: "/tmp/c", sortOrder: 2)))
        // Move the last (c) to the front.
        store.reorder(parent: nil, ids: [c.id, a.id, b.id])
        #expect(store.projects.map(\.name) == ["c", "a", "b"])
        #expect(store.projects.map(\.sortOrder) == [0, 1, 2])
    }

    // MARK: - Path normalization (a stored trailing slash reaches $PWD verbatim: fatal under nushell — the pane fails to spawn — and blanks zsh's `%c` prompt)

    @Test
    func add_strips_trailing_slash_from_local_path() {
        let store = makeStore()
        store.add(Project(name: "junk", path: "/tmp/junk/", sortOrder: 0))
        #expect(store.projects.first?.path == "/tmp/junk")
    }

    @Test
    func add_leaves_remote_path_verbatim() {
        let store = makeStore()
        store.add(Project(name: "api", path: "devbox:~/dev/api/", sortOrder: 0))
        #expect(store.projects.first?.path == "devbox:~/dev/api/")
    }

    @Test
    func setPath_normalizes_the_new_path() throws {
        let store = makeStore()
        let p = try #require(store.add(Project(name: "x", path: "/tmp/before", sortOrder: 0)))
        store.setPath(id: p.id, to: "/tmp/after/")
        #expect(store.projects.first { $0.id == p.id }?.path == "/tmp/after")
    }

    @Test
    func readV1_migrates_paths_stored_with_trailing_slashes() throws {
        let legacy = Project(name: "legacy", path: "/tmp/legacy/", sortOrder: 0)
        #expect(try readV1(JSONEncoder().encode([legacy])).rows.first?.path == "/tmp/legacy")
    }

    // MARK: - A relaunch

    @Test
    func the_projects_persist_across_a_relaunch() throws {
        let state = TestModel.appState()
        let writer = TestModel.projectStore(state)
        let a = try #require(writer.add(Project(name: "alpha", path: "/tmp/alpha", sortOrder: 0)))
        let b = try #require(writer.add(Project(name: "beta", path: "/tmp/beta", sortOrder: 1)))

        // A new app on the same server sees the same projects.
        let gui = GUIStateStore(fileURL: TestModel.folder().appending(path: "gui-state.json"))
        let reader = TestModel.projectStore(TestModel.relaunch(state, guiStateStore: gui))
        #expect(reader.projects.map(\.name) == ["alpha", "beta"])
        #expect(reader.projects.map(\.path) == ["/tmp/alpha", "/tmp/beta"])
        #expect(reader.projects.map(\.id) == [a.id, b.id])
    }

    // MARK: - v1's projects.json

    @Test
    func a_v1_file_that_does_not_read_fails_the_read_and_is_never_written() throws {
        let fileURL = tempURL("corrupt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let garbage = Data("{ not valid json".utf8)
        try garbage.write(to: fileURL)

        let v1 = ProjectStore.readV1(fileURL: fileURL)
        #expect(v1.failed)
        #expect(v1.rows.isEmpty)
        #expect(try Data(contentsOf: fileURL) == garbage)
        #expect(ProjectStore.readV1(fileURL: tempURL("missing")).failed == false)
    }

    @Test
    func a_v1_file_from_before_groups_reads() throws {
        let v1 = try readV1(Data("""
        [
          {"createdAt": 0, "id": "11111111-1111-1111-1111-111111111111", "name": "b", "path": "/tmp/b", "sortOrder": 1},
          {"colorName": "blue", "createdAt": 0, "id": "22222222-2222-2222-2222-222222222222", "name": "a", "path": "/tmp/a", "sortOrder": 0}
        ]
        """.utf8))
        #expect(!v1.failed)
        #expect(v1.rows.map(\.name) == ["b", "a"])
        #expect(v1.rows.allSatisfy { $0.hasFolder && $0.parent == nil })
        #expect(v1.rows[1].color == .blue)
    }

    /// A dev build wrote a group as a row with `kind: group` (PR 910).
    @Test
    func an_old_group_row_reads_as_a_project_with_no_folder() throws {
        let group = UUID()
        let inner = UUID()
        let v1 = try readV1(Data("""
        [
          {"colorName": "green", "createdAt": 0, "id": "\(group)", "kind": "group",
           "name": "work", "path": "/tmp/stale", "sortOrder": 0},
          {"createdAt": 0, "id": "\(inner)", "kind": "group",
           "name": "client", "parent": "\(group)", "path": "", "sortOrder": 0},
          {"createdAt": 0, "id": "33333333-3333-3333-3333-333333333333",
           "name": "api", "parent": "\(inner)", "path": "/tmp/api", "sortOrder": 0},
          {"createdAt": 0, "id": "44444444-4444-4444-4444-444444444444", "kind": "project",
           "name": "top", "path": "/tmp/top", "sortOrder": 1}
        ]
        """.utf8))
        #expect(!v1.failed)
        #expect(v1.rows.map(\.name) == ["work", "client", "api", "top"])
        let work = try #require(v1.rows.first { $0.id == group })
        #expect(!work.hasFolder)
        #expect(work.color == .green)
        #expect(work.parent == nil)
        #expect(v1.rows.first { $0.id == inner }?.parent == group)
        #expect(v1.rows.filter { $0.parent == inner }.map(\.name) == ["api"])
    }

    @Test
    func an_unknown_kind_is_ignored() throws {
        let v1 = try readV1(Data("""
        [
          {"createdAt": 0, "id": "11111111-1111-1111-1111-111111111111", "kind": "board", "name": "b", "path": "/tmp/b", "sortOrder": 0},
          {"createdAt": 0, "id": "22222222-2222-2222-2222-222222222222", "kind": 7, "name": "c", "path": "/tmp/c", "sortOrder": 1}
        ]
        """.utf8))
        #expect(!v1.failed)
        #expect(v1.rows.map(\.path) == ["/tmp/b", "/tmp/c"])
    }

    @Test
    func an_unknown_parent_reads_as_the_top_level() throws {
        let project = Project(name: "orphan", path: "/tmp/o", parent: UUID())
        let leaf = Project(name: "leaf", path: "/tmp/l")
        let v1 = try readV1(JSONEncoder().encode([leaf, project]))
        #expect(!v1.failed)
        #expect(v1.rows.map(\.name) == ["leaf", "orphan"])
        #expect(v1.rows.allSatisfy { $0.parent == nil })
    }

    @Test
    func a_parent_loop_reads_as_the_top_level() throws {
        var a = Project(name: "a", path: "/tmp/a")
        var b = Project(name: "b", path: "/tmp/b")
        a.parent = b.id
        b.parent = a.id
        let leaf = Project(name: "leaf", path: "/tmp/leaf", parent: b.id)
        let v1 = try readV1(JSONEncoder().encode([a, b, leaf]))
        // One link of the loop breaks: `a` goes to the top level, `b`
        // stays in it.
        #expect(v1.rows.filter { $0.parent == nil }.map(\.id) == [a.id])
        #expect(v1.rows.first { $0.id == b.id }?.parent == a.id)
        #expect(v1.rows.first { $0.id == leaf.id }?.parent == b.id)
    }

    // MARK: - Tree (design 013)

    @Test
    func projects_lists_every_project_in_tree_order() throws {
        let store = makeStore()
        let first = try #require(store.add(Project(name: "first", path: "/tmp/1")))
        let parent = try #require(store.add(Project(name: "parent", path: "")))
        let inner = try #require(store.add(Project(name: "inner", path: "/tmp/2", parent: parent.id)))
        let nested = try #require(store.add(Project(name: "nested", path: "/tmp/n", parent: parent.id)))
        let deep = try #require(store.add(Project(name: "deep", path: "/tmp/3", parent: nested.id)))
        let last = try #require(store.add(Project(name: "last", path: "/tmp/4")))

        #expect(store.projects.map(\.id) == [first.id, parent.id, inner.id, nested.id, deep.id, last.id])
        #expect(store.children(of: nil).map(\.id) == [first.id, parent.id, last.id])
        #expect(store.children(of: parent.id).map(\.id) == [inner.id, nested.id])
    }

    @Test
    func set_path_gives_a_project_with_no_folder_one() throws {
        let store = makeStore()
        let stored = try #require(store.add(Project(name: "p", path: "")))
        #expect(!stored.hasFolder)
        #expect(store.project(matchingPath: "") == nil)
        store.setPath(id: stored.id, to: "/tmp/p/")
        #expect(store.row(stored.id)?.path == "/tmp/p")
        #expect(store.project(matchingPath: "/tmp/p")?.id == stored.id)
    }

    @Test
    func move_puts_a_project_at_the_end_of_its_new_parent() throws {
        let store = makeStore()
        let parent = try #require(store.add(Project(name: "parent", path: "/tmp/parent")))
        let a = try #require(store.add(Project(name: "a", path: "/tmp/a", parent: parent.id)))
        let b = try #require(store.add(Project(name: "b", path: "/tmp/b")))
        let c = try #require(store.add(Project(name: "c", path: "/tmp/c")))

        #expect(store.move(b.id, into: parent.id))
        #expect(store.children(of: parent.id).map(\.id) == [a.id, b.id])
        #expect(store.children(of: nil).map(\.id) == [parent.id, c.id])

        #expect(store.move(a.id, into: nil))
        #expect(store.children(of: nil).map(\.id) == [parent.id, c.id, a.id])
        #expect(store.children(of: parent.id).map(\.id) == [b.id])
    }

    @Test
    func move_refuses_a_loop_or_an_unknown_parent() throws {
        let store = makeStore()
        let outer = try #require(store.add(Project(name: "outer", path: "/tmp/outer")))
        let inner = try #require(store.add(Project(name: "inner", path: "", parent: outer.id)))
        let other = try #require(store.add(Project(name: "o", path: "/tmp/o")))

        #expect(!store.move(outer.id, into: outer.id))
        #expect(!store.move(outer.id, into: inner.id))
        #expect(!store.move(other.id, into: UUID()))
        #expect(!store.move(UUID(), into: nil))
        #expect(store.children(of: nil).map(\.id) == [outer.id, other.id])
    }

    @Test
    func reorder_orders_the_children_of_one_parent() throws {
        let store = makeStore()
        let parent = try #require(store.add(Project(name: "parent", path: "/tmp/parent")))
        let a = try #require(store.add(Project(name: "a", path: "/tmp/a", parent: parent.id)))
        let b = try #require(store.add(Project(name: "b", path: "/tmp/b", parent: parent.id)))
        let c = try #require(store.add(Project(name: "c", path: "/tmp/c", parent: parent.id)))
        let top = try #require(store.add(Project(name: "top", path: "/tmp/top")))

        // `top` is not a child of `parent`: ignored. `b` is not named: last.
        store.reorder(parent: parent.id, ids: [c.id, top.id, a.id, c.id])
        #expect(store.children(of: parent.id).map(\.id) == [c.id, a.id, b.id])
        #expect(store.children(of: parent.id).map(\.sortOrder) == [0, 1, 2])
        #expect(store.children(of: nil).map(\.id) == [parent.id, top.id])
        #expect(store.projects.map(\.id) == [parent.id, c.id, a.id, b.id, top.id])
    }

    @Test
    func move_into_the_same_parent_keeps_the_place() throws {
        let store = makeStore()
        let a = try #require(store.add(Project(name: "a", path: "/tmp/a")))
        let b = try #require(store.add(Project(name: "b", path: "/tmp/b")))
        #expect(store.move(a.id, into: nil))
        #expect(store.children(of: nil).map(\.id) == [a.id, b.id])
    }

    @Test
    func on_save_gets_every_project() throws {
        let store = makeStore()
        var saved: [Project] = []
        store.onSave = { saved = $0 }
        let parent = try #require(store.add(Project(name: "parent", path: "")))
        let a = try #require(store.add(Project(name: "a", path: "/tmp/a", parent: parent.id)))
        #expect(saved.map(\.id) == [parent.id, a.id])
    }

    @Test
    func on_add_gets_each_stored_project() throws {
        let store = makeStore()
        var added: [Project] = []
        store.onAdd = { added.append($0) }
        let a = try #require(store.create(name: "a", path: "/tmp/a/"))
        #expect(added.map(\.id) == [a.id])
        #expect(added.first?.path == "/tmp/a", "the project as stored")
    }

    @Test
    func move_out_puts_the_project_after_its_parent() throws {
        let store = makeStore()
        let parent = try #require(store.add(Project(name: "p", path: "/tmp/p")))
        let a = try #require(store.add(Project(name: "a", path: "/tmp/a", parent: parent.id)))
        let b = try #require(store.add(Project(name: "b", path: "/tmp/b")))
        store.moveOut(a.id)
        #expect(store.children(of: nil).map(\.id) == [parent.id, a.id, b.id])
        store.moveOut(a.id)
        #expect(store.children(of: nil).map(\.id) == [parent.id, a.id, b.id], "a top-level project does not move")
    }

    @Test
    func move_among_siblings_stays_in_the_parent() throws {
        let store = makeStore()
        let a = try #require(store.add(Project(name: "a", path: "/tmp/a")))
        let parent = try #require(store.add(Project(name: "p", path: "/tmp/p")))
        let b = try #require(store.add(Project(name: "b", path: "/tmp/b", parent: parent.id)))
        let c = try #require(store.add(Project(name: "c", path: "/tmp/c", parent: parent.id)))
        store.moveAmongSiblings(c.id, by: -1)
        #expect(store.children(of: parent.id).map(\.id) == [c.id, b.id])
        store.moveAmongSiblings(c.id, by: -1)
        #expect(store.children(of: parent.id).map(\.id) == [c.id, b.id], "the first child does not move up")
        store.moveAmongSiblings(a.id, by: 1)
        #expect(store.children(of: nil).map(\.id) == [parent.id, a.id])
        #expect(store.siblingPosition(of: a.id)?.index == 1)
        #expect(store.siblingPosition(of: a.id)?.count == 2)
    }

    @Test
    func remove_with_descendants_removes_every_project_inside() throws {
        let state = TestModel.appState()
        let store = TestModel.projectStore(state)
        let parent = try #require(store.add(Project(name: "p", path: "/tmp/p")))
        let a = try #require(store.add(Project(name: "a", path: "/tmp/a", parent: parent.id)))
        let inner = try #require(store.add(Project(name: "inner", path: "", parent: parent.id)))
        let b = try #require(store.add(Project(name: "b", path: "/tmp/b", parent: inner.id)))
        let c = try #require(store.add(Project(name: "c", path: "/tmp/c")))
        #expect(store.descendants(of: parent.id).map(\.id) == [a.id, inner.id, b.id])
        state.removeProject(parent.id, store: store)
        #expect(store.projects.map(\.id) == [c.id])
        #expect(store.row(inner.id) == nil)
    }
}
