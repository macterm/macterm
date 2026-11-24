import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectStoreTests {
    private func makeStore(fileURL: URL? = nil) -> ProjectStore {
        ProjectStore(fileURL: fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-tests-\(UUID().uuidString).json"))
    }

    @Test
    func find_or_create_reuses_canonical_local_path() {
        let store = makeStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-\(UUID().uuidString)", isDirectory: true)
            .path
        let existing = Project(name: "existing", path: base + "/./", sortOrder: 0)
        store.add(existing)

        let project = store.findOrCreate(name: "duplicate", path: base)

        #expect(project.id == existing.id)
        #expect(project.name == "existing")
        #expect(store.projects.count == 1)
    }

    @Test
    func create_tags_a_new_project_only_when_auto_assign_is_on() {
        let store = makeStore()
        // Default (preference off): a new project carries no tag.
        #expect(store.create(name: "plain", path: "/tmp/a").color == nil)

        store.autoAssignsColors = { true }
        let first = store.create(name: "auto", path: "/tmp/b")
        let second = store.create(name: "auto2", path: "/tmp/c")

        #expect(first.color != nil)
        #expect(second.color != nil)
        // Distinct: the second sees the first's tag as already used.
        #expect(first.color != second.color)
        // The untagged one stays untagged — the setting is read at creation
        // only, never applied retroactively.
        #expect(store.projects.first?.color == nil)
    }

    @Test
    func set_color_tags_untags_and_persists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-color-\(UUID().uuidString).json")
        let store = makeStore(fileURL: url)
        let project = store.create(name: "tagged", path: "/tmp")

        store.setColor(id: project.id, to: .blue)
        #expect(store.projects.first?.color == .blue)
        // Written through, not just held in memory: a reopened store sees it.
        #expect(ProjectStore(fileURL: url).projects.first?.color == .blue)

        store.setColor(id: project.id, to: nil)
        #expect(store.projects.first?.color == nil)
        #expect(ProjectStore(fileURL: url).projects.first?.colorName == nil)
    }

    @Test
    func create_always_appends_even_for_a_matching_path() {
        // Removing the one-project-per-directory constraint: `create` never
        // dedups, so the same directory can back several independent projects.
        let store = makeStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-\(UUID().uuidString)", isDirectory: true)
            .path
        let first = store.create(name: "one", path: base)
        let second = store.create(name: "two", path: base + "/./")

        #expect(first.id != second.id)
        #expect(store.projects.count == 2)
        // Both normalize to the same canonical path — distinct projects, one dir.
        #expect(store.projects.map(\.path) == [first.path, first.path])
        #expect(store.projects.map(\.name) == ["one", "two"])
    }

    @Test
    func create_disambiguates_the_pinned_workspaces_name() {
        // Every creation path funnels here, and most name a project after its
        // folder — a name nobody chose, so it is suffixed rather than refused.
        let store = makeStore()
        #expect(store.create(name: "Pinned", path: "/tmp/a").name == "Pinned 2")
        #expect(store.create(name: "pinned", path: "/tmp/b").name == "pinned 2")
        #expect(store.findOrCreate(name: "PINNED", path: "/tmp/c").name == "PINNED 2")
        // Only the name itself is reserved.
        #expect(store.create(name: "Pinned Tabs", path: "/tmp/d").name == "Pinned Tabs")
        #expect(store.create(name: "Pinned 2", path: "/tmp/e").name == "Pinned 2")
        #expect(store.projects.map(\.name) == ["Pinned 2", "pinned 2", "PINNED 2", "Pinned Tabs", "Pinned 2"])
    }

    @Test
    func rename_refuses_the_pinned_workspaces_name() {
        let store = makeStore()
        let project = store.create(name: "alpha", path: "/tmp")

        store.rename(id: project.id, to: "Pinned")
        store.rename(id: project.id, to: " pinned ")
        #expect(store.projects.first?.name == "alpha")

        store.rename(id: project.id, to: "Pinned Tabs")
        #expect(store.projects.first?.name == "Pinned Tabs")
    }

    @Test
    func rename_refuses_a_slash() {
        let store = makeStore()
        let project = store.create(name: "alpha", path: "/tmp")
        store.rename(id: project.id, to: "Work/api")
        #expect(store.projects.first?.name == "alpha")
    }

    @Test
    func create_changes_each_slash_to_a_hyphen() {
        // A name nobody typed (the `name:` of a layout file) is changed, not
        // refused, as a reserved name is.
        let store = makeStore()
        #expect(store.create(name: "Work/api/lib", path: "/tmp/a").name == "Work-api-lib")
        #expect(store.create(name: "Pinned/", path: "/tmp/b").name == "Pinned-")
        #expect(store.create(name: "api", path: "/tmp/c").name == "api")
    }

    @Test
    func a_stored_name_with_a_slash_still_loads() throws {
        // Names from before the rule stay as they are (0226 converts them).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-slash-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ProjectStore(fileURL: url)
        var project = Project(name: "placeholder", path: "/tmp")
        project = first.add(project)
        let data = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"placeholder\"", with: "\"Work\\/api\"")
        try data.write(to: url, atomically: true, encoding: .utf8)

        let second = ProjectStore(fileURL: url)
        #expect(!second.loadFailed)
        #expect(second.projects.map(\.name) == ["Work/api"])
        #expect(second.projects.first?.id == project.id)
    }

    @Test
    func find_or_create_reuses_matching_remote_path() {
        let store = makeStore()
        let existing = Project(name: "api", path: "devbox:~/dev/api", sortOrder: 0)
        store.add(existing)

        let project = store.findOrCreate(
            name: "duplicate",
            path: "devbox:~/dev/api"
        )

        #expect(project.id == existing.id)
        #expect(project.name == "api")
        #expect(store.projects.count == 1)
    }

    // MARK: - Mutators

    @Test
    func remove_drops_the_project() {
        let store = makeStore()
        let a = Project(name: "a", path: "/tmp/a", sortOrder: 0)
        let b = Project(name: "b", path: "/tmp/b", sortOrder: 1)
        store.add(a)
        store.add(b)
        store.remove(id: a.id)
        #expect(store.projects.map(\.id) == [b.id])
    }

    @Test
    func rename_changes_name_but_not_identity_or_path() {
        let store = makeStore()
        let p = Project(name: "old", path: "/tmp/x", sortOrder: 0)
        store.add(p)
        store.rename(id: p.id, to: "new")
        let updated = store.projects.first { $0.id == p.id }
        #expect(updated?.name == "new")
        #expect(updated?.path == "/tmp/x")
    }

    @Test
    func setPath_updates_the_path() {
        let store = makeStore()
        let p = Project(name: "x", path: "/tmp/before", sortOrder: 0)
        store.add(p)
        store.setPath(id: p.id, to: "/tmp/after")
        #expect(store.projects.first { $0.id == p.id }?.path == "/tmp/after")
    }

    @Test
    func reorder_reindexes_sortOrder() {
        let store = makeStore()
        let a = Project(name: "a", path: "/tmp/a", sortOrder: 0)
        let b = Project(name: "b", path: "/tmp/b", sortOrder: 1)
        let c = Project(name: "c", path: "/tmp/c", sortOrder: 2)
        store.add(a)
        store.add(b)
        store.add(c)
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
    func setPath_normalizes_the_new_path() {
        let store = makeStore()
        let p = Project(name: "x", path: "/tmp/before", sortOrder: 0)
        store.add(p)
        store.setPath(id: p.id, to: "/tmp/after/")
        #expect(store.projects.first { $0.id == p.id }?.path == "/tmp/after")
    }

    @Test
    func load_migrates_paths_stored_with_trailing_slashes() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-migrate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        // Write the legacy on-disk form directly — the store's own mutators
        // normalize now, so a pre-fix file has to be crafted by hand.
        let legacy = Project(name: "legacy", path: "/tmp/legacy/", sortOrder: 0)
        try JSONEncoder().encode([legacy]).write(to: fileURL)

        let store = makeStore(fileURL: fileURL)
        #expect(store.projects.first?.path == "/tmp/legacy")
    }

    // MARK: - On-disk round-trip

    @Test
    func round_trips_through_the_file() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let writer = makeStore(fileURL: fileURL)
        let a = Project(name: "alpha", path: "/tmp/alpha", sortOrder: 0)
        let b = Project(name: "beta", path: "/tmp/beta", sortOrder: 1)
        writer.add(a)
        writer.add(b)

        // A fresh store reading the same file sees the persisted contents.
        let reader = makeStore(fileURL: fileURL)
        #expect(reader.projects.map(\.name) == ["alpha", "beta"])
        #expect(reader.projects.map(\.path) == ["/tmp/alpha", "/tmp/beta"])
        #expect(reader.projects.map(\.id) == [a.id, b.id])
    }

    // MARK: - Corrupt-file save refusal (data-loss regression, #4.6)

    @Test
    func save_refuses_after_corrupt_load_so_a_mutation_cannot_clobber() throws {
        // A present-but-undecodable projects.json must NOT be overwritten by the
        // first subsequent mutation — that would wipe the user's project list.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let garbage = Data("{ not valid json".utf8)
        try garbage.write(to: fileURL)

        // init loads (and latches the failure); a mutation then triggers save().
        let store = makeStore(fileURL: fileURL)
        #expect(store.projects.isEmpty)
        store.add(Project(name: "alpha", path: "/tmp/alpha", sortOrder: 0))

        // The corrupt file is preserved, not clobbered with the empty/new state.
        #expect(try Data(contentsOf: fileURL) == garbage)
    }

    // MARK: - Tree (design 013: groups hold projects; a project never has children)

    private func tempURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-\(label)-\(UUID().uuidString).json")
    }

    @Test
    func a_file_from_before_groups_decodes_and_saves_without_the_new_keys() throws {
        let fileURL = tempURL("old")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let old = """
        [
          {"createdAt": 0, "id": "11111111-1111-1111-1111-111111111111", "name": "b", "path": "/tmp/b", "sortOrder": 1},
          {"colorName": "blue", "createdAt": 0, "id": "22222222-2222-2222-2222-222222222222", "name": "a", "path": "/tmp/a", "sortOrder": 0}
        ]
        """
        try Data(old.utf8).write(to: fileURL)

        let store = makeStore(fileURL: fileURL)
        #expect(store.projects.map(\.name) == ["a", "b"])
        #expect(store.projects.allSatisfy { $0.hasFolder && $0.parent == nil })
        #expect(store.children(of: nil).map(\.name) == ["a", "b"])

        store.rename(id: store.projects[0].id, to: "a2")
        let written = try #require(String(data: Data(contentsOf: fileURL), encoding: .utf8))
        #expect(!written.contains("\"parent\""))
        #expect(!written.contains("\"kind\""))
    }

    @Test
    func parents_round_trip_through_the_file() {
        let fileURL = tempURL("tree")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let writer = makeStore(fileURL: fileURL)
        let work = writer.add(Project(name: "work", path: "/tmp/work"))
        let client = writer.add(Project(name: "client", path: "", parent: work.id))
        let api = writer.add(Project(name: "api", path: "/tmp/api", parent: client.id))
        writer.setColor(id: work.id, to: .green)

        let reader = makeStore(fileURL: fileURL)
        #expect(reader.children(of: nil).map(\.id) == [work.id])
        #expect(reader.children(of: nil).first?.color == .green)
        #expect(reader.children(of: work.id).map(\.id) == [client.id])
        #expect(reader.children(of: client.id).map(\.id) == [api.id])
        #expect(reader.projects.map(\.id) == [work.id, client.id, api.id])
    }

    /// A dev build wrote a group as a row with `kind: group` (PR 910).
    @Test
    func an_old_group_row_reads_as_a_project_with_no_folder() throws {
        let fileURL = tempURL("old-group")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let group = UUID()
        let inner = UUID()
        try Data("""
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
        """.utf8).write(to: fileURL)

        let store = makeStore(fileURL: fileURL)
        #expect(!store.loadFailed)
        #expect(store.projects.map(\.name) == ["work", "client", "api", "top"])
        let work = try #require(store.row(group))
        #expect(!work.hasFolder)
        #expect(work.color == .green)
        #expect(work.parent == nil)
        #expect(store.row(inner)?.parent == work.id)
        #expect(store.children(of: inner).map(\.name) == ["api"])

        store.rename(id: work.id, to: "work2")
        let written = try #require(String(data: Data(contentsOf: fileURL), encoding: .utf8))
        #expect(!written.contains("\"kind\""))
        #expect(written.contains("\"parent\""))
    }

    @Test
    func an_unknown_kind_is_ignored() throws {
        let fileURL = tempURL("kind")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("""
        [
          {"createdAt": 0, "id": "11111111-1111-1111-1111-111111111111", "kind": "board", "name": "b", "path": "/tmp/b", "sortOrder": 0},
          {"createdAt": 0, "id": "22222222-2222-2222-2222-222222222222", "kind": 7, "name": "c", "path": "/tmp/c", "sortOrder": 1}
        ]
        """.utf8).write(to: fileURL)

        let store = makeStore(fileURL: fileURL)
        #expect(!store.loadFailed)
        #expect(store.projects.map(\.path) == ["/tmp/b", "/tmp/c"])
    }

    @Test
    func projects_lists_every_project_in_tree_order() {
        let store = makeStore()
        let first = store.add(Project(name: "first", path: "/tmp/1"))
        let parent = store.add(Project(name: "parent", path: ""))
        let inner = store.add(Project(name: "inner", path: "/tmp/2", parent: parent.id))
        let nested = store.add(Project(name: "nested", path: "/tmp/n", parent: parent.id))
        let deep = store.add(Project(name: "deep", path: "/tmp/3", parent: nested.id))
        let last = store.add(Project(name: "last", path: "/tmp/4"))

        #expect(store.projects.map(\.id) == [first.id, parent.id, inner.id, nested.id, deep.id, last.id])
        #expect(store.children(of: nil).map(\.id) == [first.id, parent.id, last.id])
        #expect(store.children(of: parent.id).map(\.id) == [inner.id, nested.id])
    }

    @Test
    func set_path_gives_a_project_with_no_folder_one() {
        let store = makeStore()
        let stored = store.add(Project(name: "p", path: ""))
        #expect(!stored.hasFolder)
        #expect(store.project(matchingPath: "") == nil)
        store.setPath(id: stored.id, to: "/tmp/p/")
        #expect(store.row(stored.id)?.path == "/tmp/p")
        #expect(store.project(matchingPath: "/tmp/p")?.id == stored.id)
    }

    @Test
    func an_unknown_parent_reads_as_the_top_level() throws {
        let fileURL = tempURL("orphan")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let project = Project(name: "orphan", path: "/tmp/o", parent: UUID())
        let leaf = Project(name: "leaf", path: "/tmp/l")
        try JSONEncoder().encode([leaf, project]).write(to: fileURL)

        let store = makeStore(fileURL: fileURL)
        #expect(!store.loadFailed)
        #expect(store.projects.map(\.name) == ["leaf", "orphan"])
        #expect(store.children(of: nil).count == 2)
    }

    @Test
    func a_parent_loop_reads_as_the_top_level() throws {
        let fileURL = tempURL("loop")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        var a = Project(name: "a", path: "/tmp/a")
        var b = Project(name: "b", path: "/tmp/b")
        a.parent = b.id
        b.parent = a.id
        let leaf = Project(name: "leaf", path: "/tmp/leaf", parent: b.id)
        try JSONEncoder().encode([a, b, leaf]).write(to: fileURL)

        let store = makeStore(fileURL: fileURL)
        // One link of the loop breaks: `a` goes to the top level, `b`
        // stays in it.
        #expect(store.children(of: nil).map(\.id) == [a.id])
        #expect(store.projects.map(\.id) == [a.id, b.id, leaf.id])
    }

    @Test
    func move_puts_a_project_at_the_end_of_its_new_parent() {
        let store = makeStore()
        let parent = store.add(Project(name: "parent", path: "/tmp/parent"))
        let a = store.add(Project(name: "a", path: "/tmp/a", parent: parent.id))
        let b = store.add(Project(name: "b", path: "/tmp/b"))
        let c = store.add(Project(name: "c", path: "/tmp/c"))

        #expect(store.move(b.id, into: parent.id))
        #expect(store.children(of: parent.id).map(\.id) == [a.id, b.id])
        #expect(store.children(of: nil).map(\.id) == [parent.id, c.id])
        #expect(store.children(of: nil).map(\.sortOrder) == [0, 1])

        #expect(store.move(a.id, into: nil))
        #expect(store.children(of: nil).map(\.id) == [parent.id, c.id, a.id])
        #expect(store.children(of: parent.id).map(\.sortOrder) == [0])
    }

    @Test
    func move_refuses_a_loop_or_an_unknown_parent() {
        let store = makeStore()
        let outer = store.add(Project(name: "outer", path: "/tmp/outer"))
        let inner = store.add(Project(name: "inner", path: "", parent: outer.id))
        let other = store.add(Project(name: "o", path: "/tmp/o"))

        #expect(!store.move(outer.id, into: outer.id))
        #expect(!store.move(outer.id, into: inner.id))
        #expect(!store.move(other.id, into: UUID()))
        #expect(!store.move(UUID(), into: nil))
        #expect(store.children(of: nil).map(\.id) == [outer.id, other.id])
    }

    @Test
    func reorder_orders_the_children_of_one_parent() {
        let store = makeStore()
        let parent = store.add(Project(name: "parent", path: "/tmp/parent"))
        let a = store.add(Project(name: "a", path: "/tmp/a", parent: parent.id))
        let b = store.add(Project(name: "b", path: "/tmp/b", parent: parent.id))
        let c = store.add(Project(name: "c", path: "/tmp/c", parent: parent.id))
        let top = store.add(Project(name: "top", path: "/tmp/top"))

        // `top` is not a child of `parent`: ignored. `b` is not named: last.
        store.reorder(parent: parent.id, ids: [c.id, top.id, a.id, c.id])
        #expect(store.children(of: parent.id).map(\.id) == [c.id, a.id, b.id])
        #expect(store.children(of: parent.id).map(\.sortOrder) == [0, 1, 2])
        #expect(store.children(of: nil).map(\.id) == [parent.id, top.id])
        #expect(store.projects.map(\.id) == [parent.id, c.id, a.id, b.id, top.id])
    }

    @Test
    func removing_a_parent_moves_its_children_to_the_end_of_the_top_level() {
        let store = makeStore()
        let parent = store.add(Project(name: "parent", path: "/tmp/parent"))
        let top = store.add(Project(name: "top", path: "/tmp/top"))
        let x = store.add(Project(name: "x", path: "/tmp/x", parent: parent.id))
        let y = store.add(Project(name: "y", path: "/tmp/y", parent: parent.id))
        store.remove(id: parent.id)
        #expect(store.children(of: nil).map(\.id) == [top.id, x.id, y.id])
        #expect(store.children(of: nil).map(\.sortOrder) == [0, 1, 2])
        #expect(store.projects.map(\.id) == [top.id, x.id, y.id])
    }

    @Test
    func move_into_the_same_parent_keeps_the_place() {
        let store = makeStore()
        let a = store.add(Project(name: "a", path: "/tmp/a"))
        let b = store.add(Project(name: "b", path: "/tmp/b"))
        #expect(store.move(a.id, into: nil))
        #expect(store.children(of: nil).map(\.id) == [a.id, b.id])
    }

    @Test
    func on_save_gets_every_project() {
        let store = makeStore()
        var saved: [Project] = []
        store.onSave = { saved = $0 }
        let parent = store.add(Project(name: "parent", path: ""))
        let a = store.add(Project(name: "a", path: "/tmp/a", parent: parent.id))
        #expect(saved.map(\.id) == [parent.id, a.id])
    }

    @Test
    func move_out_puts_the_project_after_its_parent() {
        let store = makeStore()
        let parent = store.add(Project(name: "p", path: "/tmp/p"))
        let a = store.add(Project(name: "a", path: "/tmp/a", parent: parent.id))
        let b = store.add(Project(name: "b", path: "/tmp/b"))
        store.moveOut(a.id)
        #expect(store.children(of: nil).map(\.id) == [parent.id, a.id, b.id])
        store.moveOut(a.id)
        #expect(store.children(of: nil).map(\.id) == [parent.id, a.id, b.id], "a top-level project does not move")
    }

    @Test
    func move_among_siblings_stays_in_the_parent() {
        let store = makeStore()
        let a = store.add(Project(name: "a", path: "/tmp/a"))
        let parent = store.add(Project(name: "p", path: "/tmp/p"))
        let b = store.add(Project(name: "b", path: "/tmp/b", parent: parent.id))
        let c = store.add(Project(name: "c", path: "/tmp/c", parent: parent.id))
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
    func add_beside_a_project_goes_after_it_in_its_parent() {
        let store = makeStore()
        let outer = store.add(Project(name: "outer", path: "/tmp/outer"))
        let a = store.add(Project(name: "a", path: "/tmp/a", parent: outer.id))
        let b = store.add(Project(name: "b", path: "/tmp/b", parent: outer.id))
        let new = store.add(Project(name: "new", path: ""), beside: a.id)
        #expect(store.children(of: outer.id).map(\.id) == [a.id, new.id, b.id])
        let top = store.add(Project(name: "top", path: ""), beside: nil)
        #expect(store.children(of: nil).map(\.id) == [outer.id, top.id])
    }

    @Test
    func remove_keeping_children_puts_them_at_the_place_of_the_parent() {
        let store = makeStore()
        let a = store.add(Project(name: "a", path: "/tmp/a"))
        let parent = store.add(Project(name: "p", path: "/tmp/p"))
        let b = store.add(Project(name: "b", path: "/tmp/b", parent: parent.id))
        let inner = store.add(Project(name: "inner", path: "", parent: parent.id))
        let deep = store.add(Project(name: "deep", path: "/tmp/d", parent: inner.id))
        let c = store.add(Project(name: "c", path: "/tmp/c"))
        store.removeKeepingChildren(parent.id)
        #expect(store.children(of: nil).map(\.id) == [a.id, b.id, inner.id, c.id])
        #expect(store.row(parent.id) == nil)
        #expect(store.projects.map(\.id) == [a.id, b.id, inner.id, deep.id, c.id])
    }

    @Test
    func remove_with_descendants_removes_every_project_inside() {
        let store = makeStore()
        let parent = store.add(Project(name: "p", path: "/tmp/p"))
        let a = store.add(Project(name: "a", path: "/tmp/a", parent: parent.id))
        let inner = store.add(Project(name: "inner", path: "", parent: parent.id))
        let b = store.add(Project(name: "b", path: "/tmp/b", parent: inner.id))
        let c = store.add(Project(name: "c", path: "/tmp/c"))
        #expect(store.descendants(of: parent.id).map(\.id) == [a.id, inner.id, b.id])
        store.removeWithDescendants(parent.id)
        #expect(store.projects.map(\.id) == [c.id])
        #expect(store.row(inner.id) == nil)
    }
}
