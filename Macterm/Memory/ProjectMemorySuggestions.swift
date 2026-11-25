import Foundation

/// The commands that the panel's Suggested section offers, from what the
/// on-device model chose (`ProjectMemorySummarizer`). Pure.
///
/// **The model chooses and orders; it never invents a command that the
/// panel will run.** A click types the command into a shell, so a
/// suggestion is kept only when it is a command that ran in this project
/// (`candidates`), or one of `safeGitCommands`. Anything else the model
/// proposes is dropped. A git command is kept only when the Git state
/// gives it a reason, and a destructive one never
/// (`gitStateSupports`). Without suggestions the panel shows no Suggested
/// section, as it shows no summary: a command is never suggested only
/// because it ran recently.
enum ProjectMemorySuggestions {
    static let limit = 5
    /// How many of the project's commands the model chooses from.
    static let candidateLimit = 30

    /// Git commands that read, or pull, and that the model may suggest
    /// although they never ran in the project.
    static let safeGitCommands = ["git status", "git pull", "git fetch", "git diff", "git log", "git stash list"]

    /// The commands the model may choose from: the project's own, newest
    /// first, with no duplicates, nothing trivial and nothing masked. A
    /// failure that the panel does not show is not one
    /// (`ProjectMemorySummary.withoutSettledFailures`).
    static func candidates(entries: [MemoryEntry]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in ProjectMemorySummary.withoutSettledFailures(entries).reversed() {
            guard let command = entry.command else { continue }
            let normalized = MemoryCommand.normalized(command)
            guard !MemoryCommand.isTrivial(normalized), !MemoryCommand.isMasked(normalized), !seen.contains(normalized)
            else { continue }
            seen.insert(normalized)
            result.append(normalized)
            if result.count == candidateLimit { break }
        }
        return result
    }

    /// The model's suggestions as rows, in its order: only known commands,
    /// each one time, at most `limit`. The folder is where the command last
    /// ran. A git command is kept only when the Git state supports it
    /// (`gitStateSupports`): with nothing in the log, the model padded the
    /// list with every allowed git command and a reason it made up (`git
    /// pull` "behind the remote" in a repository with no remote).
    static func actions(from suggestions: [OnDeviceModel.Suggestion], entries: [MemoryEntry], git: GitStatus? = nil) -> [QuickAction] {
        let known = Set(candidates(entries: entries) + safeGitCommands)
        var taken: Set<String> = []
        var actions: [QuickAction] = []
        for suggestion in suggestions {
            let command = MemoryCommand.normalized(suggestion.command)
            guard known.contains(command), !taken.contains(command), gitStateSupports(command, git: git) else { continue }
            taken.insert(command)
            let last = entries.last { $0.command.map(MemoryCommand.normalized) == command }
            actions.append(QuickAction(
                title: command,
                subtitle: suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                command: command,
                directory: last?.directory
            ))
            if actions.count == limit { break }
        }
        return actions
    }

    /// Whether the Git state gives a git command a reason. A command with
    /// no git in it is not judged here. Each git part of a compound command
    /// (`;`, `|`, `&`) must pass on its own:
    ///
    /// - A destructive one (`isDestructive`) never passes, even when the log
    ///   has it: a click types it into a shell. `git clean -fd` was offered
    ///   in a clean tree because the log had it and nothing judged it.
    /// - With no Git state (no repository), none passes.
    /// - Each subcommand needs its reason: a pull needs commits behind, a
    ///   plain push commits ahead, a fetch an upstream; status, diff, add,
    ///   commit and a plain stash need changes; a stash list or a stash pop
    ///   needs stashes. A log always reads. Any other subcommand, or an
    ///   option before the subcommand (`git -C repo push`), never passes.
    static func gitStateSupports(_ command: String, git: GitStatus?) -> Bool {
        let invocations = gitInvocations(in: command)
        guard !invocations.isEmpty else { return true }
        guard let git else { return false }
        return invocations.allSatisfy { supports($0, git: git) }
    }

    /// The git invocations in `command`, each as the words after `git`. A
    /// part's leading `NAME=value` words are skipped (`GIT_DIR=x git push`).
    static func gitInvocations(in command: String) -> [[String]] {
        command.split(whereSeparator: { ";|&\n".contains($0) }).compactMap { part in
            let words = part.split(whereSeparator: \.isWhitespace).map(String.init)
                .drop { $0.contains("=") && !$0.hasPrefix("-") }
            guard words.first == "git" else { return nil }
            return Array(words.dropFirst())
        }
    }

    private static func supports(_ words: [String], git: GitStatus) -> Bool {
        guard let subcommand = words.first, !isDestructive(words) else { return false }
        let arguments = words.dropFirst()
        switch subcommand {
        case "pull": return git.behind > 0
        case "push": return arguments.isEmpty && git.ahead > 0
        case "fetch": return git.upstream != nil
        case "log": return true
        case "status",
             "diff",
             "add",
             "commit": return !git.isClean
        case "stash":
            switch arguments.first {
            case nil: return !git.isClean
            case "list",
                 "pop": return arguments.count == 1 && git.stashes > 0
            default: return false
            }
        default: return false
        }
    }

    /// Whether a git invocation (the words after `git`) can lose work that
    /// is not committed, or rewrite history. Matched on the subcommand and
    /// its options, never on a substring.
    static func isDestructive(_ words: [String]) -> Bool {
        guard let subcommand = words.first else { return false }
        let arguments = Array(words.dropFirst())
        let has = { (option: String) in arguments.contains(option) }
        switch subcommand {
        case "clean",
             "rebase",
             "filter-branch": return true
        case "reset": return has("--hard") || has("--merge")
        case "checkout": return has(".") || has("--") || has("-f") || has("--force")
        case "restore":
            return !(has("--staged") || has("-S")) || has("--worktree") || has("-W")
        case "push":
            return arguments.contains { $0.hasPrefix("--force") || $0.hasPrefix("+")
                || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f"))
            }
        case "branch": return has("-D")
        case "stash": return arguments.first == "drop" || arguments.first == "clear"
        case "gc": return arguments.contains { $0.hasPrefix("--prune") }
        default: return false
        }
    }
}
