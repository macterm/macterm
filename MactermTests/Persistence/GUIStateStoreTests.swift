import Foundation
@testable import Macterm
import Testing

/// `gui-state.json`: what only the GUI keeps (the windows, the pinned
/// records, the widgets' records).
@MainActor
struct GUIStateStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("macterm-tests-gui-\(UUID().uuidString).json")
    }

    @Test
    func pinned_records_round_trip_through_the_store() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let records = [
            PinnedRecordState(id: UUID(), declaration: LayoutTab(layout: .pane(LayoutPane(cwd: "/tmp"))), originProjectID: UUID()),
            PinnedRecordState(
                id: UUID(),
                declaration: LayoutTab(name: "unloaded", layout: .pane(LayoutPane(run: "btop"))),
                originProjectID: nil
            ),
        ]
        GUIStateStore(fileURL: url).save(GUIStateFile(version: GUIStateStore.currentVersion, pinned: records))

        let loaded = try #require(GUIStateStore(fileURL: url).load())

        let pinned = try #require(loaded.pinned)
        #expect(pinned.map(\.id) == records.map(\.id))
        #expect(pinned[0].originProjectID == records[0].originProjectID)
        #expect(pinned[1].originProjectID == nil)
        #expect(pinned[1].declaration == records[1].declaration)
        #expect(loaded.windows == nil)
    }

    @Test
    func a_missing_file_loads_nil_and_saves() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GUIStateStore(fileURL: url)
        #expect(store.load() == nil)
        #expect(!store.loadFailed)
        #expect(!store.existed)
        store.save(GUIStateFile(version: GUIStateStore.currentVersion))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A file that does not read must not be written over: that would lose
    /// the user's windows and pinned records.
    @Test
    func save_refuses_after_a_file_that_did_not_read() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let garbage = Data("{ corrupt not json".utf8)
        try garbage.write(to: url)

        let store = GUIStateStore(fileURL: url)
        #expect(store.load() == nil)
        #expect(store.loadFailed)
        store.save(GUIStateFile(version: GUIStateStore.currentVersion))

        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test
    func save_refuses_over_a_file_of_a_newer_build() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let newer = Data(#"{"version": 99}"#.utf8)
        try newer.write(to: url)

        let store = GUIStateStore(fileURL: url)
        #expect(store.load()?.version == 99)
        #expect(store.loadFailed)
        store.save(GUIStateFile(version: GUIStateStore.currentVersion))

        #expect(try Data(contentsOf: url) == newer)
    }
}
