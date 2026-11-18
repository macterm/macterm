import AppKit
@testable import Macterm
import Testing

/// Serialized: the open dialog is one static value.
@MainActor @Suite(.serialized)
struct NewRemoteProjectDialogTests {
    /// A check that answers when the test says so.
    @MainActor
    final class Check {
        private(set) var paths: [String] = []
        private var waiting: CheckedContinuation<String?, Never>?

        func run(_ path: String) async -> String? {
            paths.append(path)
            return await withCheckedContinuation { waiting = $0 }
        }

        func answer(_ refusal: String?) {
            waiting?.resume(returning: refusal)
            waiting = nil
        }

        var isWaiting: Bool {
            waiting != nil
        }
    }

    final class Created {
        var projects: [(name: String, path: String)] = []
    }

    private func dialog(_ draft: NewRemoteProjectDraft? = nil, check: Check, created: Created) -> NewRemoteProjectDialog {
        NewRemoteProjectDialog(draft: draft, refusal: { await check.run($0) }, create: { created.projects.append(($0, $1)) })
    }

    /// Polls `done`, with a sleep, as the check runs in a task.
    private func settle(_ done: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func type(_ text: String, in field: NSTextField, of dialog: NewRemoteProjectDialog) {
        field.stringValue = text
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    // MARK: - The draft

    @Test
    func a_draft_gives_back_the_path_that_the_palette_parsed() throws {
        for path in ["devbox:~/dev/api", "me@devbox:/srv/app", "devbox:~"] {
            let draft = try #require(NewRemoteProjectDraft(path: path), "\(path)")
            #expect(ProjectPath.composeRemote(host: draft.host, directory: draft.directory) == path)
        }
    }

    @Test
    func only_a_remote_path_makes_a_draft() {
        for path in ["/srv/app", "~/dev/api", ""] {
            #expect(NewRemoteProjectDraft(path: path) == nil, "\(path)")
        }
    }

    // MARK: - The steps

    @Test
    func add_checks_the_folder_and_adds_the_project_named_after_the_folder() async {
        let check = Check()
        let created = Created()
        let dialog = dialog(check: check, created: created)
        dialog.present(on: nil, startCheck: false)
        #expect(!dialog.alert.buttons[0].isEnabled)
        type("me@devbox", in: dialog.hostField, of: dialog)
        type("~/dev/api", in: dialog.directoryField, of: dialog)
        #expect(dialog.nameField.placeholderString == "api")
        dialog.alert.buttons[0].performClick(nil)

        #expect(dialog.isChecking)
        #expect(!dialog.hostField.isEnabled)
        #expect(!dialog.alert.buttons[0].isEnabled)
        #expect(dialog.statusText == "Connecting to me@devbox…")
        #expect(NewRemoteProjectDialog.checking("me@devbox") === dialog)
        await settle { check.isWaiting }
        check.answer(nil)
        await settle { !created.projects.isEmpty }
        #expect(created.projects.map(\.name) == ["api"])
        #expect(created.projects.map(\.path) == ["me@devbox:~/dev/api"])
        #expect(NewRemoteProjectDialog.current == nil)
    }

    @Test
    func a_refusal_adds_nothing_and_an_edit_removes_its_line() async throws {
        let check = Check()
        let created = Created()
        let draft = try #require(NewRemoteProjectDraft(path: "devbox:~/none"))
        let dialog = dialog(draft, check: check, created: created)
        // The palette's draft checks at once.
        dialog.present(on: nil, startCheck: true)
        #expect(dialog.isChecking)
        await settle { check.isWaiting }
        check.answer("There is no folder ~/none on devbox.")
        await settle { !dialog.isChecking }

        #expect(created.projects.isEmpty)
        #expect(dialog.statusText == "There is no folder ~/none on devbox.")
        #expect(dialog.hostField.isEnabled)
        #expect(NewRemoteProjectDialog.checking("devbox") == nil)
        // The name follows the corrected folder.
        type("~/dev/api", in: dialog.directoryField, of: dialog)
        #expect(dialog.statusText.isEmpty)
        #expect(dialog.nameField.placeholderString == "api")
        dialog.close()
    }

    @Test
    func the_install_question_is_the_next_step_of_the_same_dialog() async throws {
        let check = Check()
        let created = Created()
        let draft = try #require(NewRemoteProjectDraft(path: "devbox:~/dev/api"))
        let dialog = dialog(draft, check: check, created: created)
        dialog.present(on: nil, startCheck: true)
        await settle { check.isWaiting }

        for (button, expected) in [(0, true), (1, false)] {
            let answer = Task { await RemoteServerConsent.ask("devbox") }
            await settle { dialog.isAskingInstall }
            #expect(dialog.alert.messageText == RemoteServerConsent.title("devbox"))
            #expect(dialog.alert.buttons.map(\.title) == [RemoteServerConsent.installButton, RemoteServerConsent.withoutServerButton])
            #expect(dialog.alert.accessoryView == nil)
            dialog.alert.buttons[button].performClick(nil)
            #expect(await answer.value == expected)
            // Back to the check, in the same dialog.
            #expect(dialog.isChecking)
            #expect(dialog.alert.messageText == "New Remote Project")
            #expect(dialog.alert.buttons.map(\.title) == ["Add", "Cancel"])
        }
        check.answer(nil)
        await settle { !created.projects.isEmpty }
        #expect(created.projects.map(\.path) == ["devbox:~/dev/api"])
    }

    @Test
    func cancel_during_the_install_question_answers_no_and_adds_nothing() async throws {
        let check = Check()
        let created = Created()
        let draft = try #require(NewRemoteProjectDraft(path: "devbox:~/dev/api"))
        let dialog = dialog(draft, check: check, created: created)
        dialog.present(on: nil, startCheck: true)
        await settle { check.isWaiting }
        let answer = Task { await dialog.askInstall() }
        await settle { dialog.isAskingInstall }
        dialog.close()
        #expect(await answer.value == false)
        check.answer(nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(created.projects.isEmpty)
        #expect(NewRemoteProjectDialog.current == nil)
    }
}
