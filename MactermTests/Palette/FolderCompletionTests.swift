import Foundation
@testable import Macterm
import Testing

/// The folder rows of a typed path from any listing (0614): a host's rows
/// are the rows of a local path.
@MainActor
struct FolderCompletionTests {
    private func makeTree() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-folder-rows-\(UUID().uuidString)", isDirectory: true)
        for name in ["src/app", "scripts", "Samples", ".swiftpm", "docs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("setup.sh"))
        return root.path
    }

    @Test
    func a_listing_gives_the_rows_that_the_local_completer_gives() throws {
        let root = try makeTree()
        for typed in [
            root + "/",
            root + "/s",
            root + "/S",
            root + "/src",
            root + "/src/",
            root + "/.s",
            root + "/none",
            root + "/setup.sh",
        ] {
            let local = PathCompleter.complete(typed)
            let expected = local.map { completion in
                (completion.exactMatch.map { [$0] } ?? []) + completion.children
            }
            let rows = FolderCompletion.rows(for: typed, listing: localListing)
            #expect(
                rows?.map(\.path).map(trimmed) == expected?.map(trimmed),
                "\(typed): the same folders in the same order"
            )
            if let rows, let completion = local {
                #expect(
                    rows.map(\.fieldText) == ((completion.exactMatch.map { [$0] } ?? []) + completion.children)
                        .map { PathCompleter.fieldText(for: $0, typed: typed) },
                    "\(typed): Tab puts the same text in the field"
                )
            }
        }
    }

    @Test
    func a_host_listing_gives_rows_with_the_hosts_paths_and_the_typed_text() {
        let listings = [
            "~/": FolderListing(path: "/home/me", names: ["proj", "projects", ".config", "notes"]),
            "~/proj/": FolderListing(path: "/home/me/proj", names: ["api", "web"]),
        ]
        let listing = { (folder: String) in listings[folder] }
        #expect(FolderCompletion.rows(for: "~/pro", listing: listing) == [
            .init(path: "/home/me/proj", fieldText: "~/proj/"),
            .init(path: "/home/me/projects", fieldText: "~/projects/"),
        ])
        #expect(FolderCompletion.rows(for: "~/proj", listing: listing) == [
            .init(path: "/home/me/proj", fieldText: "~/proj/"),
            .init(path: "/home/me/proj/api", fieldText: "~/proj/api/"),
            .init(path: "/home/me/proj/web", fieldText: "~/proj/web/"),
        ], "a typed folder, then the folders in it")
        #expect(FolderCompletion.rows(for: "~", listing: listing)?.first == .init(path: "/home/me", fieldText: "~/"))
        #expect(FolderCompletion.rows(for: "~/.c", listing: listing)?.map(\.path) == ["/home/me/.config"], "hidden after a dot")
        #expect(FolderCompletion.rows(for: "~/x", listing: listing)?.isEmpty == true, "nothing matches")
        #expect(FolderCompletion.rows(for: "/srv/", listing: listing) == nil, "no listing yet")
        #expect(FolderCompletion.rows(for: "api", listing: listing) == nil, "a path from / or ~ only")
        #expect(
            FolderCompletion.rows(for: "/", listing: { _ in FolderListing(path: "/", names: ["usr"]) })?.map(\.path) == ["/", "/usr"]
        )
    }

    @Test
    func the_lister_asks_once_for_each_folder_and_tells_the_screen() async throws {
        var asked: [String] = []
        let lister = HostFolderLister { folder in
            asked.append(folder)
            return folder == "~/" ? FolderListing(path: "/home/me", names: ["proj"]) : nil
        }
        var changes = 0
        lister.onChange = { changes += 1 }
        #expect(lister.listing("~/") == nil, "asked, not there yet")
        #expect(lister.isListing)
        #expect(lister.listing("~/") == nil)
        try await waitUntil { changes == 1 }
        #expect(lister.listing("~/")?.names == ["proj"])
        #expect(!lister.isListing)
        _ = lister.listing("/none/")
        try await waitUntil { changes == 2 }
        #expect(lister.listing("/none/") == nil, "no answer gives no rows")
        #expect(!lister.isListing, "a folder with no answer waits before it is asked again")
        #expect(asked == ["~/", "/none/"])
    }

    @Test
    func the_lister_keeps_the_newest_listings() async throws {
        let lister = HostFolderLister { folder in FolderListing(path: "/" + folder, names: []) }
        var changes = 0
        lister.onChange = { changes += 1 }
        for index in 0 ... HostFolderLister.kept {
            _ = lister.listing("f\(index)/")
            try await waitUntil { changes == index + 1 }
        }
        #expect(lister.listing("f\(HostFolderLister.kept)/") != nil, "the newest stays")
        #expect(lister.listing("f1/") != nil, "only the oldest goes")
        #expect(lister.listing("f0/") == nil, "the oldest went, and is asked again")
        #expect(lister.isListing)
    }

    @Test
    func a_cancelled_request_tells_nothing() async throws {
        let lister = HostFolderLister { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return FolderListing(path: "/srv", names: ["a"])
        }
        var changes = 0
        lister.onChange = { changes += 1 }
        _ = lister.listing("/srv/")
        lister.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes == 0)
        #expect(!lister.isListing)
    }

    @Test
    func an_input_screen_draws_again_when_a_listing_comes() async throws {
        let lister = HostFolderLister { _ in FolderListing(path: "/srv", names: ["a"]) }
        let scope = InputPaletteScope(input: PaletteInput(
            id: "test.host-folders",
            title: "Folder",
            prompt: "Folder",
            hostFolders: lister
        ) { _, _ in .nothing })
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("macterm-hf-\(UUID().uuidString)")
        let context = PaletteContext(
            appState: AppState(
                workspaceStore: WorkspaceStore(fileURL: base.appendingPathComponent("w.json")),
                projectFiles: ProjectFileStore(directoryURL: base.appendingPathComponent("p", isDirectory: true))
            ),
            projectStore: ProjectStore(fileURL: base.appendingPathComponent("s.json"))
        )
        var redraws = 0
        scope.activate(context: context) { redraws += 1 }
        _ = lister.listing("/srv/")
        #expect(scope.loading != nil, "the field shows the spinner while the host lists")
        try await waitUntil { redraws == 1 }
        #expect(scope.loading == nil)
        scope.deactivate()
        #expect(lister.onChange == nil)
    }

    /// The listing of a local folder, read as `PathCompleter` reads it:
    /// `~` expands, and a link to a folder counts as a folder.
    private func localListing(_ directory: String) -> FolderListing? {
        let expanded = (directory as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/"), fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? fm.contentsOfDirectory(atPath: expanded)
        else { return nil }
        let path = trimmed(expanded)
        let folders = names.filter { name in
            var child: ObjCBool = false
            return fm.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &child) && child.boolValue
        }
        return FolderListing(path: path, names: folders)
    }

    private func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Poll until `condition` holds, with a sleep, or fail after 2 s.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
