import SwiftUI

/// The fields of a new remote project that the palette parsed from a typed
/// `host:folder` (0358). The sheet opens with them and checks at once.
struct NewRemoteProjectDraft: Equatable {
    var name: String
    var host: String
    var directory: String

    /// The draft for a typed scp-style path, nil for any other text.
    init?(path: String, name: String) {
        guard case let .remote(user, host, directory) = ProjectPath.parse(path) else { return nil }
        self.name = name
        self.host = HostCommands.destination(user: user, host: host)
        self.directory = directory
    }
}

/// "New Project → Remote Machine" (#104): collects a display name, an ssh
/// destination (`[user@]host` or an ssh-config alias — port/identity/
/// ControlMaster live in `~/.ssh/config`), and a remote directory, composing
/// them into the scp-style `Project.path`. Validation is `ProjectPath`'s:
/// the Add button enables only when the fields form a well-formed remote
/// spec. Add then connects to the host as a pane does (the login and the
/// server install may ask) and adds the project only when the folder is
/// there (`RemoteHosts.checkFolder`, 0358). A missing folder or a host that
/// does not answer shows a row, and nothing is added. The palette opens it
/// with a `NewRemoteProjectDraft`, and the check starts at once, so a typed
/// `host:folder` shows the same progress and the same refusal.
///
/// A grouped form with no background of its own, so that the sheet's
/// material (liquid glass on macOS 26) shows through, and large buttons, as
/// the sheets of System Settings.
struct NewRemoteProjectSheet: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @Environment(\.dismiss)
    private var dismiss

    /// The palette's fields, checked when the sheet opens.
    private let draft: NewRemoteProjectDraft?

    @State
    private var name: String
    @State
    private var host: String
    @State
    private var directory: String
    /// The folder check that runs, from Add. Cancel stops it.
    @State
    private var check: Task<Void, Never>?
    /// Why the last Add added nothing. An edit clears it.
    @State
    private var failure: String?
    /// The draft's check started: a second appear does not start it again.
    @State
    private var startedDraft = false

    init(draft: NewRemoteProjectDraft? = nil) {
        self.draft = draft
        _name = State(initialValue: draft?.name ?? "")
        _host = State(initialValue: draft?.host ?? "")
        _directory = State(initialValue: draft?.directory ?? "~")
    }

    private var composedPath: String? {
        ProjectPath.composeRemote(host: host, directory: directory)
    }

    /// A typed name a sentinel workspace reserves: refused here like every
    /// typed name (`Project.reservedNameMessage`). An empty field falls back
    /// to the host, which nobody typed as a name, so `ProjectStore.create`
    /// suffixes that one instead.
    private var reservedNameMessage: String? {
        Project.reservedNameMessage(for: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Remote Project")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)
            Form {
                Section {
                    // The check adds the path that it checked.
                    Group {
                        TextField("Name", text: $name, prompt: Text(verbatim: host.isEmpty ? "devbox" : host))
                        TextField("Host", text: $host, prompt: Text("[user@]host or ssh alias"))
                        TextField("Directory", text: $directory, prompt: Text(verbatim: "~/dev/api"))
                    }
                    .disabled(check != nil)
                    // The section's footnote: its last row, as in Settings.
                    Text("""
                    Each pane is a session on the host, over one ssh connection. \
                    At the first connection, Macterm asks to install its server on the host. \
                    Port, identity, and ControlMaster come from ~/.ssh/config.
                    """)
                    .settingsSecondaryText()
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let message = reservedNameMessage ?? failure {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(MactermTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            HStack(spacing: 8) {
                if check != nil {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting to \(host.trimmingCharacters(in: .whitespaces))…")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    check?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(composedPath == nil || reservedNameMessage != nil || check != nil)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: [name, host, directory]) { failure = nil }
        .onAppear {
            guard draft != nil, !startedDraft else { return }
            startedDraft = true
            add()
        }
        .onDisappear { check?.cancel() }
    }

    private func add() {
        guard let path = composedPath, reservedNameMessage == nil, check == nil else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        failure = nil
        check = Task {
            let refusal = await RemoteHosts.shared.refusal(forNewProjectPath: path)
            check = nil
            guard !Task.isCancelled else { return }
            if let refusal {
                failure = refusal
                return
            }
            // Always create: a directory can back several projects, so a
            // repeat host:dir here adds a distinct project rather than
            // reusing the last.
            let project = projectStore.create(name: trimmedName.isEmpty ? trimmedHost : trimmedName, path: path)
            appState.selectProject(project)
            dismiss()
        }
    }
}
