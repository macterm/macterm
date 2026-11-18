@testable import Macterm
import Testing

struct NewRemoteProjectSheetTests {
    @Test
    func a_draft_gives_back_the_path_that_the_palette_parsed() throws {
        for path in ["devbox:~/dev/api", "me@devbox:/srv/app", "devbox:~"] {
            let draft = try #require(NewRemoteProjectDraft(path: path, name: "api"), "\(path)")
            #expect(draft.name == "api")
            #expect(ProjectPath.composeRemote(host: draft.host, directory: draft.directory) == path)
        }
    }

    @Test
    func only_a_remote_path_makes_a_draft() {
        for path in ["/srv/app", "~/dev/api", ""] {
            #expect(NewRemoteProjectDraft(path: path, name: "x") == nil, "\(path)")
        }
    }
}
