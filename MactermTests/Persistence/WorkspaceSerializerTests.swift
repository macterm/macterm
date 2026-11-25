import Foundation
@testable import Macterm
import Testing

/// v1's `workspaces_v3.json`, as the import reads it (design/010 §8): the
/// read of the file (`WorkspaceStore.load`) and the check that keeps one
/// pane on one session (`WorkspaceSerializer.withoutRepeatedSessions`).
/// `ModelConversionTests` tests what the import makes of it.
@MainActor
struct WorkspaceSerializerTests {
    private func tempFile(_ name: String = "ws") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("macterm-tests-\(name)-\(UUID().uuidString).json")
    }

    private func paneSnapshot(_ path: String = "/tmp", session: String? = nil) -> PaneSnapshot {
        let id = UUID()
        return PaneSnapshot(
            id: id,
            projectPath: path,
            sessionID: id,
            sessionName: session ?? ZmxSessionName.make(projectName: "tmp", paneSessionID: id)
        )
    }

    private func tab(_ panes: [PaneSnapshot], focused: UUID? = nil) -> TabSnapshot {
        let nodes = panes.map { SplitNodeSnapshot.pane($0) }
        let root = nodes.dropFirst().reduce(nodes[0]) { first, second in
            .split(SplitBranchSnapshot(direction: .horizontal, ratio: 0.5, first: first, second: second))
        }
        return TabSnapshot(id: UUID(), customTitle: nil, focusedPaneID: focused, splitRoot: root)
    }

    private func names(_ t: TabSnapshot?) -> [String?] {
        guard let t else { return [] }
        func walk(_ node: SplitNodeSnapshot) -> [String?] {
            switch node {
            case let .pane(p): [p.sessionName]
            case let .split(b): walk(b.first) + walk(b.second)
            }
        }
        return walk(t.splitRoot)
    }

    // MARK: - The read

    /// A file from an older build still has `needsAttention` and
    /// `completionFailed`. It reads, and the keys are ignored.
    @Test
    func a_file_with_the_old_attention_keys_loads_and_ignores_them() throws {
        let tmp = tempFile()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let projectID = UUID()
        let old = """
        {"version": 6, "workspaces": [{"projectID": "\(projectID.uuidString)", "tabs": [{
            "id": "\(UUID().uuidString)",
            "splitRoot": {"type": "pane", "pane": {
                "id": "\(UUID().uuidString)", "projectPath": "/tmp",
                "needsAttention": true, "completionFailed": true
            }}
        }]}]}
        """
        try old.write(to: tmp, atomically: true, encoding: .utf8)
        let store = WorkspaceStore(fileURL: tmp)

        let loaded = store.load()

        #expect(!store.loadFailed)
        #expect(loaded.workspaces.map(\.projectID) == [projectID])
        #expect(loaded.workspaces.first?.tabs.count == 1)
    }

    /// The quick terminal's tab has its own section, with the session names
    /// as they were saved.
    @Test
    func the_quick_terminal_section_loads_with_its_session_names() throws {
        let tmp = tempFile()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let quick = tab([paneSnapshot(session: "macterm-quick-a"), paneSnapshot(session: "macterm-quick-b")])
        let file = WorkspacesFile(version: 6, workspaces: [], quickTerminal: quick)
        try JSONEncoder().encode(file).write(to: tmp)

        let loaded = WorkspaceStore(fileURL: tmp).load()

        let snapshot = try #require(loaded.quickTerminal)
        #expect(snapshot.id == quick.id)
        #expect(names(snapshot) == ["macterm-quick-a", "macterm-quick-b"])
    }

    /// A file from before the section existed loads with no quick terminal.
    /// The key is optional and never a decode failure.
    @Test
    func a_file_without_a_quick_terminal_section_loads_nil() throws {
        let tmp = tempFile()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"version": 6, "workspaces": [], "pinned": [], "windows": []}"#.write(to: tmp, atomically: true, encoding: .utf8)
        let store = WorkspaceStore(fileURL: tmp)
        #expect(store.load().quickTerminal == nil)
        #expect(!store.loadFailed)
    }

    @Test
    func the_bare_array_of_the_oldest_files_loads() throws {
        let tmp = tempFile()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let snapshot = WorkspaceSnapshot(projectID: UUID(), activeTabID: nil, tabs: [tab([paneSnapshot()])])
        try JSONEncoder().encode([snapshot]).write(to: tmp)
        let store = WorkspaceStore(fileURL: tmp)
        #expect(store.load().workspaces.map(\.projectID) == [snapshot.projectID])
        #expect(!store.loadFailed)
    }

    @Test
    func load_from_missing_file_returns_empty() {
        let store = WorkspaceStore(fileURL: tempFile("doesnotexist"))
        #expect(store.load().workspaces.isEmpty)
        #expect(!store.loadFailed)
    }

    /// A file that does not read gives nothing and sets `loadFailed`: the
    /// import then imports nothing, and tries again at the next launch.
    @Test
    func load_from_malformed_file_returns_empty_and_fails() throws {
        let tmp = tempFile("malformed")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let garbage = Data("not valid json {".utf8)
        try garbage.write(to: tmp)
        let store = WorkspaceStore(fileURL: tmp)
        #expect(store.load().workspaces.isEmpty)
        #expect(store.loadFailed)
        #expect(try Data(contentsOf: tmp) == garbage, "the read never writes the file")
    }

    @Test
    func a_file_of_a_newer_build_fails() throws {
        let tmp = tempFile("newer")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"version": 99, "workspaces": []}"#.write(to: tmp, atomically: true, encoding: .utf8)
        let store = WorkspaceStore(fileURL: tmp)
        _ = store.load()
        #expect(store.loadFailed)
    }

    // MARK: - One pane, one session

    @Test
    func a_tab_with_two_panes_on_one_session_keeps_the_first_pane_alone() {
        // `pane mirror` of older builds put a second pane on a session in
        // the same tab. One pane is one session, so the second pane goes,
        // and its sibling takes its space.
        let first = paneSnapshot()
        let repeated = paneSnapshot(session: first.sessionName)
        let other = paneSnapshot()
        let root = SplitNodeSnapshot.split(SplitBranchSnapshot(
            direction: .horizontal,
            ratio: 0.5,
            first: .pane(first),
            second: .split(SplitBranchSnapshot(direction: .vertical, ratio: 0.5, first: .pane(repeated), second: .pane(other)))
        ))
        let projectID = UUID()
        var loaded = WorkspaceStore.Loaded()
        loaded.workspaces = [WorkspaceSnapshot(
            projectID: projectID,
            activeTabID: nil,
            tabs: [TabSnapshot(id: UUID(), customTitle: nil, focusedPaneID: repeated.id, splitRoot: root)]
        )]

        let kept = WorkspaceSerializer.withoutRepeatedSessions(loaded, validIDs: [projectID])

        #expect(names(kept.workspaces.first?.tabs.first) == [first.sessionName, other.sessionName])
    }

    @Test
    func a_repeated_session_id_keeps_one_pane() {
        let sessionID = UUID()
        let keep = PaneSnapshot(id: UUID(), projectPath: "/tmp/a", sessionID: sessionID)
        let second = PaneSnapshot(id: UUID(), projectPath: "/tmp/b", sessionID: sessionID)
        var seen: Set<String> = []
        let kept = WorkspaceSerializer.withoutRepeatedSessions(tab([keep, second]), seen: &seen)
        guard case let .pane(only)? = kept?.splitRoot else {
            Issue.record("expected one leaf")
            return
        }
        #expect(only.projectPath == "/tmp/a")
    }

    @Test
    func a_pane_that_repeats_a_session_of_another_tab_is_dropped_with_its_tab() {
        // A pane of `pane mirror` could move to its own tab. That tab has no
        // pane left, so it goes.
        let first = paneSnapshot()
        let firstTab = tab([first])
        let movedTab = tab([paneSnapshot(session: first.sessionName)])
        let projectID = UUID()
        var loaded = WorkspaceStore.Loaded()
        loaded.workspaces = [WorkspaceSnapshot(projectID: projectID, activeTabID: nil, tabs: [firstTab, movedTab])]

        let kept = WorkspaceSerializer.withoutRepeatedSessions(loaded, validIDs: [projectID])

        #expect(kept.workspaces.first?.tabs.map(\.id) == [firstTab.id])
    }

    @Test
    func a_session_of_a_project_tab_stays_on_no_pinned_quick_or_widget_pane() throws {
        // A file from a build with `pane mirror` can name one session on a
        // project pane and on a pinned, quick terminal or widget pane. Only
        // the project pane keeps it.
        let projectPane = paneSnapshot()
        let session = try #require(projectPane.sessionName)
        let projectID = UUID()
        let declaration = LayoutTab(layout: .pane(LayoutPane()))
        let pinnedAlone = PinnedTabSnapshot(
            id: UUID(), declaration: declaration, originProjectID: nil, live: tab([paneSnapshot(session: session)])
        )
        let pinnedSplit = PinnedTabSnapshot(
            id: UUID(), declaration: declaration, originProjectID: nil,
            live: tab([paneSnapshot(session: session), paneSnapshot(session: "pinned-own")])
        )
        let widget = DesktopWidgetSnapshot(
            id: UUID(), tab: tab([paneSnapshot(session: session)]), columns: 2, rows: 2, topLeftX: 0, topLeftY: 0
        )
        var loaded = WorkspaceStore.Loaded()
        loaded.workspaces = [WorkspaceSnapshot(projectID: projectID, activeTabID: nil, tabs: [tab([projectPane])])]
        loaded.pinned = [pinnedAlone, pinnedSplit]
        loaded.quickTerminal = tab([paneSnapshot(session: session)])
        loaded.desktopWidgets = [widget]

        let kept = WorkspaceSerializer.withoutRepeatedSessions(loaded, validIDs: [projectID])

        #expect(kept.workspaces.flatMap { $0.tabs.flatMap { names($0) } } == [session])
        #expect(kept.pinned[0].live == nil)
        #expect(names(kept.pinned[1].live) == ["pinned-own"])
        #expect(kept.quickTerminal == nil)
        #expect(names(kept.desktopWidgets[0].tab) == [nil])
        guard case let .pane(widgetPane)? = kept.desktopWidgets[0].tab?.splitRoot,
              case let .pane(widgetBefore)? = widget.tab?.splitRoot
        else {
            Issue.record("expected leaves")
            return
        }
        #expect(widgetPane.sessionID == nil)
        // The pane id is the session id, so the fresh pane gets a new one.
        #expect(widgetPane.id != widgetBefore.id)
    }

    @Test
    func a_session_of_a_project_that_is_not_imported_stays_on_a_pinned_pane() throws {
        let projectPane = paneSnapshot()
        let session = try #require(projectPane.sessionName)
        var loaded = WorkspaceStore.Loaded()
        loaded.workspaces = [WorkspaceSnapshot(projectID: UUID(), activeTabID: nil, tabs: [tab([projectPane])])]
        loaded.pinned = [PinnedTabSnapshot(
            id: UUID(),
            declaration: LayoutTab(layout: .pane(LayoutPane())),
            originProjectID: nil,
            live: tab([paneSnapshot(session: session)])
        )]

        let kept = WorkspaceSerializer.withoutRepeatedSessions(loaded, validIDs: [])

        #expect(names(kept.pinned[0].live) == [session])
    }
}
