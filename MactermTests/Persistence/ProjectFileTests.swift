import Foundation
@testable import Macterm
import Testing

struct ProjectFileTests {
    // MARK: - Decode

    @Test
    func bare_declaration_without_tabs_decodes() throws {
        let file = try ProjectFile.parse(yaml: """
        name: API server
        path: ~/dev/api
        """)
        #expect(file.name == "API server")
        #expect(file.path == "~/dev/api")
        #expect(file.tabs == nil)
        #expect(file.layoutFile == nil)
    }

    /// v1 wrote `zmxPath:` for a remote project. The format only grows: the
    /// key still reads, does nothing and is not written back.
    @Test
    func v1_zmx_path_key_still_reads() throws {
        let file = try ProjectFile.parse(yaml: """
        path: devbox:~/dev/api
        zmxPath: ~/bin/zmx
        """)
        #expect(file.path == "devbox:~/dev/api")
        #expect(try !file.yaml().contains("zmxPath"))
    }

    /// `macterm mcp` serves the schema as `macterm://formats/layout`, and its
    /// `examples` are what an agent copies: each one is a layout that applies.
    @Test
    func the_schemas_examples_decode_to_a_layout() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/project.schema.json")
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let examples = try #require(schema["examples"] as? [Any])
        #expect(!examples.isEmpty)
        for example in examples {
            // JSON is YAML.
            let text = try String(decoding: JSONSerialization.data(withJSONObject: example), as: UTF8.self)
            #expect(try ProjectFile.parse(yaml: text).layoutFile != nil)
        }
    }

    @Test
    func empty_tabs_bridges_to_no_layout() throws {
        let file = try ProjectFile.parse(yaml: """
        path: /a/b
        tabs: []
        """)
        #expect(file.layoutFile == nil)
    }

    @Test
    func tabs_reuse_the_layout_schema() throws {
        let file = try ProjectFile.parse(yaml: """
        name: Proj
        path: /a/b
        tabs:
          - name: Dev
            split:
              direction: vertical
              ratio: 0.7
              first: { run: "npm run dev" }
              second: { }
        """)
        let layout = try #require(file.layoutFile)
        #expect(layout.name == "Proj")
        #expect(layout.tabs.count == 1)
        guard case let .split(branch) = layout.tabs[0].layout else {
            Issue.record("expected split")
            return
        }
        #expect(branch.direction == .vertical)
        #expect(branch.ratio == 0.7)
    }

    @Test
    func missing_path_fails_full_decode() {
        #expect(throws: LayoutFileError.self) {
            try ProjectFile.parse(yaml: "name: no path here")
        }
    }

    @Test
    func round_trips_through_yaml_with_modeline() throws {
        let original = ProjectFile(
            name: "API",
            path: "~/dev/api",
            tabs: [LayoutTab(name: "Dev", layout: .pane(LayoutPane(cwd: nil, run: "btop", shell: nil)))]
        )
        let text = try original.yaml()
        #expect(text.hasPrefix(ProjectFile.schemaModeline))
        #expect(try ProjectFile.parse(yaml: text) == original)
    }

    // MARK: - Header decode

    @Test
    func header_survives_tabs_schema_errors() {
        // `split` missing `second` fails the full decode but the header —
        // which never looks at tabs — still identifies the file.
        let yaml = """
        name: Broken
        path: /a/b
        tabs:
          - split: { direction: horizontal, first: { } }
        """
        #expect(throws: LayoutFileError.self) { try ProjectFile.parse(yaml: yaml) }
        let header = ProjectFile.parseHeader(yaml: yaml)
        #expect(header?.path == "/a/b")
        #expect(header?.name == "Broken")
    }

    @Test
    func header_fails_on_yaml_syntax_error() {
        #expect(ProjectFile.parseHeader(yaml: "path: [unclosed") == nil)
    }

    // MARK: - Slug

    @Test
    func slug_lowercases_and_underscores_whitespace() {
        #expect(ProjectSlug.slug(from: "API Server") == "api_server")
        #expect(ProjectSlug.slug(from: "  a  b ") == "__a__b_")
    }

    @Test
    func slug_keeps_unicode_letters_and_digits() {
        #expect(ProjectSlug.slug(from: "日本語プロジェクト") == "日本語プロジェクト")
        #expect(ProjectSlug.slug(from: "Café-2") == "café-2")
    }

    @Test
    func slug_strips_symbols_and_path_hostiles() {
        #expect(ProjectSlug.slug(from: "a/b:c*d") == "abcd")
        #expect(ProjectSlug.slug(from: "my.project!") == "myproject")
    }

    @Test
    func empty_slug_falls_back() {
        #expect(ProjectSlug.slug(from: "!!!") == "project")
        #expect(ProjectSlug.slug(from: "") == "project")
    }

    @Test
    func filename_suffixes_start_at_two() {
        #expect(ProjectSlug.filename(slug: "api", attempt: 1) == "api.yaml")
        #expect(ProjectSlug.filename(slug: "api", attempt: 2) == "api_2.yaml")
        #expect(ProjectSlug.filename(slug: "api", attempt: 3) == "api_3.yaml")
    }
}
