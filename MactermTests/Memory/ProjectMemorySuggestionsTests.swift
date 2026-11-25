import Foundation
@testable import Macterm
import Testing

struct ProjectMemorySuggestionsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ command: String?, exit: Int = 0, minutesAgo: Double, directory: String? = "/repo") -> MemoryEntry {
        MemoryEntry(
            command: command,
            directory: directory,
            exitCode: exit,
            finishedAt: now.addingTimeInterval(-minutesAgo * 60),
            duration: 1
        )
    }

    private func suggestion(_ command: String, _ reason: String = "because") -> OnDeviceModel.Suggestion {
        OnDeviceModel.Suggestion(command: command, reason: reason)
    }

    @Test
    func candidates_are_the_projects_own_commands_newest_first_with_no_noise() {
        let entries = [
            entry("make build", minutesAgo: 30),
            entry("ls", minutesAgo: 20),
            entry("export TOKEN=•••", minutesAgo: 15),
            entry("make  test", minutesAgo: 10),
            entry(nil, minutesAgo: 5),
            entry("make build", minutesAgo: 1),
        ]
        #expect(ProjectMemorySuggestions.candidates(entries: entries) == ["make build", "make test"])
    }

    @Test
    func only_known_commands_are_kept_in_the_models_order() {
        let entries = [entry("make build", minutesAgo: 30, directory: "/repo/app"), entry("make test", exit: 1, minutesAgo: 1)]
        let actions = ProjectMemorySuggestions.actions(from: [
            suggestion("make test", "The latest run failed."),
            suggestion("rm -rf /", "Clean up."),
            suggestion("git status", "See the changed files."),
            suggestion("make build"),
            suggestion("make test", "Again."),
        ], entries: entries, git: GitStatus(branch: "main", unstaged: 1))

        #expect(actions.map(\.command) == ["make test", "git status", "make build"])
        #expect(actions[0].subtitle == "The latest run failed.")
        #expect(actions[2].directory == "/repo/app")
    }

    @Test
    func a_masked_or_trivial_command_is_never_suggested() {
        let entries = [entry("curl -u me:••• https://x", minutesAgo: 2), entry("ls", minutesAgo: 1)]
        let actions = ProjectMemorySuggestions.actions(from: [suggestion("curl -u me:••• https://x"), suggestion("ls")], entries: entries)
        #expect(actions.isEmpty)
    }

    @Test
    func there_are_at_most_five_suggestions() {
        let entries = (0 ..< 10).map { entry("task \($0)", minutesAgo: Double($0)) }
        let actions = ProjectMemorySuggestions.actions(from: (0 ..< 10).map { suggestion("task \($0)") }, entries: entries)
        #expect(actions.count == ProjectMemorySuggestions.limit)
    }

    @Test
    func a_git_command_needs_a_reason_in_the_git_state() {
        var git = GitStatus(branch: "main")
        let all = ProjectMemorySuggestions.safeGitCommands.map { suggestion($0, "Because.") }

        // A clean repository with no upstream: only the log reads.
        #expect(ProjectMemorySuggestions.actions(from: all, entries: [], git: git).map(\.command) == ["git log"])

        git.upstream = "origin/main"
        git.behind = 2
        git.unstaged = 1
        git.stashes = 1
        // Every git command has a reason now; the rows stop at the limit.
        #expect(ProjectMemorySuggestions.actions(from: all, entries: [], git: git).map(\.command)
            == Array(ProjectMemorySuggestions.safeGitCommands.prefix(ProjectMemorySuggestions.limit)))

        // With no Git state, no git command passes; a project command is never judged.
        #expect(ProjectMemorySuggestions.actions(from: all, entries: [], git: nil).isEmpty)
        #expect(ProjectMemorySuggestions.gitStateSupports("make test", git: GitStatus(branch: "main")))
        #expect(ProjectMemorySuggestions.gitStateSupports("make test", git: nil))
    }

    @Test
    func a_destructive_git_command_is_never_offered_even_from_the_log() {
        let entries = [
            entry("git clean -fd", minutesAgo: 9),
            entry("git push --force", minutesAgo: 8),
            entry("git reset --hard", minutesAgo: 7),
            entry("git checkout .", minutesAgo: 6),
            entry("git restore src/a.swift", minutesAgo: 5),
            entry("git stash drop", minutesAgo: 4),
            entry("git branch -D old", minutesAgo: 3),
            entry("git rebase main", minutesAgo: 2),
            entry("make test && git push -f", minutesAgo: 1),
        ]
        let all = ProjectMemorySuggestions.candidates(entries: entries).map { suggestion($0) }
        var dirty = GitStatus(branch: "main", upstream: "origin/main")
        dirty.ahead = 2
        dirty.behind = 1
        dirty.unstaged = 3
        dirty.untracked = 1
        dirty.stashes = 2
        #expect(ProjectMemorySuggestions.actions(from: all, entries: entries, git: GitStatus(branch: "main")).isEmpty)
        #expect(ProjectMemorySuggestions.actions(from: all, entries: entries, git: dirty).isEmpty)
    }

    @Test
    func each_git_subcommand_needs_its_own_reason() {
        let supports = ProjectMemorySuggestions.gitStateSupports
        let clean = GitStatus(branch: "main", upstream: "origin/main")
        var ahead = clean
        ahead.ahead = 1
        var dirty = clean
        dirty.untracked = 1

        #expect(!supports("git push", clean))
        #expect(supports("git push", ahead))
        #expect(!supports("git push origin main --force-with-lease", ahead))
        #expect(!supports("git add -A", clean))
        #expect(supports("git add -A", dirty))
        #expect(supports("git commit -m wip", dirty))
        #expect(!supports("git stash", clean))
        #expect(supports("git stash", dirty))
        #expect(!supports("git stash pop", dirty))
        var stashed = clean
        stashed.stashes = 1
        #expect(supports("git stash pop", stashed))
        #expect(!ProjectMemorySuggestions.isDestructive(["restore", "--staged", "a.swift"]))
        #expect(ProjectMemorySuggestions.isDestructive(["restore", "a.swift"]))
        // An unknown subcommand, or an option before it, is never offered.
        #expect(!supports("git merge feature", dirty))
        #expect(!supports("git cherry-pick abc123", dirty))
        #expect(!supports("git -C repo status", dirty))
        // Every git part of a compound command must pass.
        #expect(supports("make test && git add -A", dirty))
        #expect(!supports("git add -A && git push", dirty))
        #expect(!supports("GIT_DIR=x git clean -fd", dirty))
    }
}
