@testable import Macterm
import Testing

/// The one look of a folder row in a path-completion list (`PathRow`).
struct PathRowTests {
    @Test
    func the_title_is_the_folder_name() {
        #expect(PathRow.title(for: "/Users/me/work/api") == "api")
        #expect(PathRow.title(for: "/Users/me/work/api/") == "api")
        #expect(PathRow.title(for: "/") == "/")
    }

    @Test
    func the_subtitle_is_the_words_of_the_action_and_the_full_path() {
        let path = "/Users/me/work/api"
        #expect(PathRow.Action.openAsNewProject.subtitle(for: path) == "Open as new project: /Users/me/work/api")
        #expect(PathRow.Action.switchToProject.subtitle(for: path) == "Switch to project: /Users/me/work/api")
        #expect(PathRow.Action.addAnotherProject.subtitle(for: path) == "Add another project: /Users/me/work/api")
        #expect(PathRow.Action.changeTo.subtitle(for: path) == "Change to: /Users/me/work/api")
    }
}
