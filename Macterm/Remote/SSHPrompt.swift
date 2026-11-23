import Foundation

/// The questions that a host's ssh login asks through the askpass, as data
/// (design/005 step 2): who asks, what kind of answer it takes, and what
/// Macterm knows of the text. Pure: the sheets that ask the user are
/// `SSHLoginPrompts`, behind `LoginUI`.
enum SSHPrompt {
    struct Request: Equatable {
        var host: String
        var prompt: String
        var kind: Kind
        /// The master whose askpass asks.
        var sshPID: pid_t
        /// The ssh that runs the askpass: the master, or the ssh of a
        /// `ProxyJump` host under it. nil: not known.
        var askerPID: pid_t?

        /// Who asks. Two hosts of one login can ask the same text (a key
        /// passphrase), so a retry is the same prompt from the same ssh.
        var asker: Asker {
            Asker(sshPID: sshPID, askerPID: askerPID ?? sshPID)
        }
    }

    struct Asker: Hashable {
        var sshPID: pid_t
        var askerPID: pid_t
    }

    enum Kind: Equatable {
        case secret
        /// A line of "yes" or "no" (a new host key).
        case yesNo
        /// An exit status (`SSH_ASKPASS_PROMPT=confirm`).
        case confirm

        static func of(prompt: String, confirm: Bool) -> Kind {
            if confirm { return .confirm }
            return prompt.lowercased().contains("(yes/no") ? .yesNo : .secret
        }
    }

    enum Answer: Equatable {
        case text(String)
        case cancelled
    }

    /// The same secret prompt again, from the same ssh, after an answer:
    /// ssh refused that answer.
    static func isRetry(_ request: Request, answered: [Asker: String]) -> Bool {
        request.kind == .secret && answered[request.asker] == request.prompt
    }

    /// What a question of the login is. Macterm knows a question only by the
    /// exact text that OpenSSH writes for it, and shows its own text for it.
    /// Any other text (a code of an authenticator app, a text that the host's
    /// administrator wrote) is unknown: the sheet shows only ssh's prompt
    /// line, never its other output.
    enum Question: Equatable {
        /// `bob@box's password: `, or `(bob@box) Password: ` of a
        /// keyboard-interactive login.
        case password(account: String)
        /// `Enter passphrase for key '<file>': `.
        case passphrase(key: String)
        case hostKey(HostKey)
        /// ssh's prompt line, or for a yes or no question the lines above it.
        case unknown(line: String)

        static func of(_ prompt: String, kind: Kind) -> Question {
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            switch kind {
            case .secret:
                if let account = password(in: text) { return .password(account: account) }
                if let key = passphraseKey(in: text) { return .passphrase(key: key) }
            case .yesNo:
                if let key = SSHPrompt.hostKey(in: prompt) { return .hostKey(key) }
                // A yes or no question is about the host's key (a key that
                // changed, a form that a later OpenSSH writes). Fail closed:
                // keep ssh's lines above the question, so that the host and
                // the key stay in view. The buttons ask the question.
                let lines = SSHPrompt.displayText(prompt).split(whereSeparator: \.isNewline)
                if lines.count > 1 { return .unknown(line: lines.dropLast().joined(separator: "\n")) }
            case .confirm:
                break
            }
            return .unknown(line: SSHPrompt.promptLine(prompt))
        }

        /// The sheet's text.
        var text: String {
            switch self {
            case let .password(account): String(localized: "Type the password for \(account).")
            case let .passphrase(key): String(localized: "Type the passphrase for the key \(key).")
            case .hostKey: String(localized: "The key of this host is not known. Make sure that it is the key that you expect.")
            case let .unknown(line): line
            }
        }

        /// The line in front of the text when ssh asks the same again.
        var refusal: String {
            switch self {
            case .password: String(localized: "The password is incorrect.")
            case .passphrase: String(localized: "The passphrase is incorrect.")
            case .hostKey,
                 .unknown: String(localized: "The answer is incorrect.")
            }
        }

        private static func password(in text: String) -> String? {
            if text.hasSuffix("'s password:") {
                let account = String(text.dropLast("'s password:".count))
                return isAccount(account) ? account : nil
            }
            if text.hasPrefix("("), text.hasSuffix(") Password:") {
                let account = String(text.dropFirst().dropLast(") Password:".count))
                return isAccount(account) ? account : nil
            }
            return nil
        }

        /// `user@host`, one word.
        private static func isAccount(_ text: String) -> Bool {
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
                && !text.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "(" || $0 == ")" })
        }

        private static func passphraseKey(in text: String) -> String? {
            let opening = "Enter passphrase for key '"
            let closing = "':"
            guard text.hasPrefix(opening), text.hasSuffix(closing), text.count > opening.count + closing.count else { return nil }
            let path = String(text.dropFirst(opening.count).dropLast(closing.count))
            guard !path.contains("\n") else { return nil }
            return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// The last line of ssh's prompt that has text, cleaned: what the sheet
    /// shows for a question that Macterm does not know.
    static func promptLine(_ prompt: String) -> String {
        displayText(prompt).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }

    /// The host, key type and fingerprint of ssh's question about a new host
    /// key ("The authenticity of host 'box (1.2.3.4)' can't be established."
    /// and "ED25519 key fingerprint is SHA256:…." or, from OpenSSH 10.5,
    /// "ED25519 key fingerprint is: SHA256:…"), or nil when either line
    /// is missing. With `ProxyJump` the key can be the jump host's, so the
    /// sheet shows the host that ssh names.
    static func hostKey(in prompt: String) -> HostKey? {
        let opening = "The authenticity of host '"
        var host: String?
        var key: (type: String, fingerprint: String)?
        for line in prompt.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix(opening) {
                let rest = text.dropFirst(opening.count)
                if let end = rest.firstIndex(of: "'"), end > rest.startIndex { host = String(rest[..<end]) }
                continue
            }
            let words = text.split(separator: " ")
            // OpenSSH 10.5 and later writes "is:", older releases "is".
            guard words.count == 5, words[1 ... 2] == ["key", "fingerprint"],
                  words[3] == "is" || words[3] == "is:"
            else { continue }
            var fingerprint = String(words[4])
            if fingerprint.hasSuffix(".") { fingerprint.removeLast() }
            guard fingerprint.contains(":") else { continue }
            key = (String(words[0]), fingerprint)
        }
        guard let host, let key else { return nil }
        return HostKey(host: host, type: key.type, fingerprint: key.fingerprint)
    }

    struct HostKey: Equatable {
        var host: String
        var type: String
        var fingerprint: String
    }

    /// ssh's prompt with its control characters removed, and capped.
    static func displayText(_ prompt: String) -> String {
        let scalars = prompt.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars).prefix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
