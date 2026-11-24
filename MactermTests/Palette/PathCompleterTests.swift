import Foundation
@testable import Macterm
import Testing

/// The one completer of a typed local path (`PathCompleter`), which path
/// mode and an input screen's path field share.
struct PathCompleterTests {
    /// A directory with `api`, `App`, `apps`, `docs`, `.config`, `.cache`
    /// and a file `apple.txt`.
    private func makeTree() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-path-completer-\(UUID().uuidString)", isDirectory: true)
        for name in ["api", "App", "apps", "docs", ".config", ".cache"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data().write(to: root.appendingPathComponent("apple.txt"))
        return root.path
    }

    private func names(_ completion: PathCompleter.Completion?) -> [String]? {
        completion?.children.map { ($0 as NSString).lastPathComponent }
    }

    @Test
    func a_typed_directory_is_the_exact_match_and_lists_its_visible_directories() throws {
        let root = try makeTree()
        let completion = PathCompleter.complete(root)
        #expect(completion?.exactMatch == root)
        #expect(names(completion) == ["api", "App", "apps", "docs"], "directories only, sorted, no hidden ones")
        #expect(completion?.children.first == (root as NSString).appendingPathComponent("api"))
    }

    @Test
    func the_last_component_is_a_prefix_folded_as_search_folds() throws {
        let root = try makeTree()
        let completion = PathCompleter.complete(root + "/ap")
        #expect(completion?.exactMatch == nil)
        #expect(names(completion) == ["api", "App", "apps"])
        #expect(names(PathCompleter.complete(root + "/APP")) == ["App", "apps"])
        #expect(names(PathCompleter.complete(root + "/zz"))?.isEmpty == true)
    }

    @Test
    func hidden_directories_show_only_after_a_typed_dot() throws {
        let root = try makeTree()
        #expect(names(PathCompleter.complete(root + "/.c")) == [".cache", ".config"])
        #expect(names(PathCompleter.complete(root + "/c"))?.isEmpty == true)
    }

    @Test
    func the_limit_counts_directories_in_sorted_order() throws {
        let root = try makeTree()
        #expect(names(PathCompleter.complete(root, limit: 2)) == ["api", "App"])
    }

    @Test
    func a_home_path_expands_and_anything_else_completes_to_nothing() {
        let home = NSHomeDirectory()
        #expect(PathCompleter.complete("~")?.exactMatch == home)
        #expect(PathCompleter.complete("relative/dir") == nil)
        #expect(PathCompleter.complete("devbox:~/dev") == nil, "a remote spec: nothing asks the host")
        #expect(PathCompleter.complete("/no-such-\(UUID().uuidString)/x") == nil)
    }

    @Test
    func the_field_text_ends_in_a_slash_and_keeps_a_typed_tilde() {
        let home = NSHomeDirectory()
        #expect(PathCompleter.fieldText(for: home + "/dev", typed: "~/d") == "~/dev/")
        #expect(PathCompleter.fieldText(for: home + "/dev", typed: home + "/d") == home + "/dev/")
        #expect(PathCompleter.fieldText(for: "/tmp/", typed: "/t") == "/tmp/")
    }
}
