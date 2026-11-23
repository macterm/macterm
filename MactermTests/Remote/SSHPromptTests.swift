import Foundation
@testable import Macterm
import Testing

/// The parser of ssh's askpass prompts (`SSHPrompt`).
struct SSHPromptTests {
    @Test
    func the_question_follows_the_prompt() {
        #expect(SSHPrompt.Kind.of(prompt: "bob@box's password: ", confirm: false) == .secret)
        #expect(SSHPrompt.Kind.of(
            prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
            confirm: false
        ) == .yesNo)
        #expect(SSHPrompt.Kind.of(prompt: "Allow use of key?", confirm: true) == .confirm)
    }

    @Test
    func the_shown_prompt_has_no_control_characters() {
        #expect(SSHPrompt.displayText("pass\u{1B}[31mword: \u{7}") == "pass[31mword:")
        #expect(SSHPrompt.displayText("line one\nline two") == "line one\nline two")
    }

    @Test
    func a_new_host_key_shows_its_type_and_fingerprint() throws {
        let prompt = """
        The authenticity of host 'localhost (::1)' can't be established.
        ED25519 key fingerprint is SHA256:Hx4kP3o0aB+cdEf/ghIjkLmNoPqRsTuVwXyZ0123456.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        let key = try #require(SSHPrompt.hostKey(in: prompt))
        #expect(key.host == "localhost (::1)")
        #expect(key.type == "ED25519")
        #expect(key.fingerprint == "SHA256:Hx4kP3o0aB+cdEf/ghIjkLmNoPqRsTuVwXyZ0123456")
        #expect(SSHPrompt.hostKey(in: "bob@box's password:") == nil)
        // No host line: the sheet cannot say whose key it is.
        #expect(SSHPrompt.hostKey(in: "ED25519 key fingerprint is SHA256:abc.") == nil)
    }

    @Test
    func a_new_host_key_from_openssh_10_5_has_a_colon_after_is() throws {
        // The text of OpenSSH 10.5 in the VM (UI review of PR 745).
        let prompt = """
        The authenticity of host 'localhost (::1)' can't be established.
        ED25519 key fingerprint is: SHA256:+5/x06NnIxLuUAhlw-D7oo5lEV3KR37gqnojrjti4mV0
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        let key = try #require(SSHPrompt.hostKey(in: prompt))
        #expect(key.host == "localhost (::1)")
        #expect(key.type == "ED25519")
        #expect(key.fingerprint == "SHA256:+5/x06NnIxLuUAhlw-D7oo5lEV3KR37gqnojrjti4mV0")
    }

    @Test
    func a_retry_is_the_same_prompt_from_the_same_ssh() {
        let passphrase = "Enter passphrase for key '/Users/bob/.ssh/id_ed25519': "
        let jump = SSHPrompt.Request(host: "prod", prompt: passphrase, kind: .secret, sshPID: 100, askerPID: 200)
        let destination = SSHPrompt.Request(host: "prod", prompt: passphrase, kind: .secret, sshPID: 100, askerPID: 100)
        let answered = [jump.asker: passphrase]
        #expect(SSHPrompt.isRetry(jump, answered: answered))
        // The destination asks the same text after the jump host: not a retry.
        #expect(!SSHPrompt.isRetry(destination, answered: answered))
        #expect(!SSHPrompt.isRetry(jump, answered: [:]))
    }

    @Test
    func macterm_knows_a_question_only_by_the_exact_openssh_text() {
        typealias Question = SSHPrompt.Question
        #expect(Question.of("bob@box's password: ", kind: .secret) == .password(account: "bob@box"))
        #expect(Question.of("(bob@box) Password: ", kind: .secret) == .password(account: "bob@box"))
        #expect(Question.of("Enter passphrase for key '/tmp/id_ed25519': ", kind: .secret) == .passphrase(key: "/tmp/id_ed25519"))
        let home = NSHomeDirectory()
        #expect(Question.of("Enter passphrase for key '\(home)/.ssh/id': ", kind: .secret) == .passphrase(key: "~/.ssh/id"))
        // Any other text is unknown, also when it has a known word.
        #expect(Question.of("Verification code: ", kind: .secret) == .unknown(line: "Verification code:"))
        #expect(Question.of("New password: ", kind: .secret) == .unknown(line: "New password:"))
        #expect(Question.of("Password for bob: ", kind: .secret) == .unknown(line: "Password for bob:"))
        #expect(Question.of("Allow use of key?", kind: .confirm) == .unknown(line: "Allow use of key?"))
    }

    @Test
    func an_unknown_question_shows_only_its_prompt_line() {
        let prompt = "Duo two-factor login for bob\n\nEnter a passcode or select one of the following options:\n\n"
            + "Passcode or option (1-3): \u{1B}"
        #expect(SSHPrompt.Question.of(prompt, kind: .secret).text == "Passcode or option (1-3):")
    }

    @Test
    func a_yes_no_question_that_macterm_does_not_know_keeps_the_lines_above_it() {
        // A security question fails closed: the host and the key stay in view.
        let changed = "Warning: the ECDSA host key for 'box' differs from the key for the IP address.\n"
            + "Are you sure you want to continue connecting (yes/no)?"
        #expect(SSHPrompt.Question.of(changed, kind: .yesNo)
            == .unknown(line: "Warning: the ECDSA host key for 'box' differs from the key for the IP address."))
        // A host-key text in a form that the parser does not read.
        let future = "The authenticity of host 'box (1.2.3.4)' can't be established.\n"
            + "ED25519 key fingerprint, SHA256:abc\nAre you sure you want to continue connecting (yes/no/[fingerprint])?"
        #expect(SSHPrompt.Question.of(future, kind: .yesNo)
            == .unknown(line: "The authenticity of host 'box (1.2.3.4)' can't be established.\nED25519 key fingerprint, SHA256:abc"))
        #expect(SSHPrompt.Question.of("Continue (yes/no)?", kind: .yesNo) == .unknown(line: "Continue (yes/no)?"))
    }

    @Test
    func a_password_prompt_needs_an_account_with_a_host() {
        #expect(SSHPrompt.Question.of("root's password: ", kind: .secret) == .unknown(line: "root's password:"))
        #expect(SSHPrompt.Question.of("@box's password: ", kind: .secret) == .unknown(line: "@box's password:"))
        #expect(SSHPrompt.Question.of("a b@box's password: ", kind: .secret) == .unknown(line: "a b@box's password:"))
    }

    @Test
    func a_refusal_names_only_what_macterm_knows() {
        #expect(SSHPrompt.Question.passphrase(key: "k").refusal == "The passphrase is incorrect.")
        #expect(SSHPrompt.Question.password(account: "bob@box").refusal == "The password is incorrect.")
        #expect(SSHPrompt.Question.unknown(line: "Verification code:").refusal == "The answer is incorrect.")
    }
}
