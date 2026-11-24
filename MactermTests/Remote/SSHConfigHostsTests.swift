import Foundation
@testable import Macterm
import Testing

/// The hosts of an ssh config (`SSHConfigHosts`), read from files in a
/// temp folder, never from `~/.ssh/config`.
struct SSHConfigHostsTests {
    /// A temp `.ssh` folder and a home folder around it.
    private struct Folder {
        let home: URL
        var ssh: URL { home.appendingPathComponent(".ssh") }
        var config: URL { ssh.appendingPathComponent("config") }

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("macterm-ssh-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        }

        func write(_ text: String, to path: String = "config") throws {
            let url = ssh.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func load() -> [SSHConfigHost] {
            SSHConfigHosts.load(config: config, sshDirectory: ssh, home: home.path)
        }
    }

    @Test
    func lists_each_literal_host_once_in_file_order_and_skips_comments_wildcards_and_negations() throws {
        let folder = try Folder()
        try folder.write("""
        # a comment
          # an indented comment

        Host devbox
            HostName devbox.example.com
            User me
        Host a b  !c *.internal
        Host *
            User everyone
        Host gpu?
        host devbox web
        """)
        #expect(folder.load().map(\.alias) == ["devbox", "a", "b", "web"])
    }

    @Test
    func host_name_and_user_are_the_first_value_of_each_matching_block() throws {
        let folder = try Folder()
        try folder.write("""
        User early
        Host devbox
            HostName devbox.example.com
            User me
        Host web
            HostName %h.example.com
        Host api !web
            Port 2222
        Host *
            HostName fallback.example.com
            User late
        Host plain
        """)
        let hosts = folder.load()
        #expect(hosts == [
            SSHConfigHost(alias: "devbox", hostName: "devbox.example.com", user: "early"),
            SSHConfigHost(alias: "web", hostName: "web.example.com", user: "early"),
            SSHConfigHost(alias: "api", hostName: "fallback.example.com", user: "early"),
            SSHConfigHost(alias: "plain", hostName: "fallback.example.com", user: "early"),
        ])
        #expect(hosts[0].detail == "early@devbox.example.com")
    }

    @Test
    func a_negated_pattern_keeps_a_block_from_a_host() throws {
        let folder = try Folder()
        try folder.write("""
        Host * !jump
            User me
        Host jump box
        """)
        #expect(folder.load() == [
            SSHConfigHost(alias: "jump", hostName: nil, user: nil),
            SSHConfigHost(alias: "box", hostName: nil, user: "me"),
        ])
    }

    @Test
    func a_match_block_is_not_read() throws {
        let folder = try Folder()
        try folder.write("""
        Match host devbox exec "true"
            User matched
        Host devbox
            HostName devbox.example.com
        """)
        #expect(folder.load() == [SSHConfigHost(alias: "devbox", hostName: "devbox.example.com", user: nil)])
    }

    @Test
    func include_follows_relative_tilde_and_glob_paths_in_order() throws {
        let folder = try Folder()
        try folder.write("""
        Host first
        Include conf.d/*.conf ~/.ssh/extra "~/.ssh/with space"
        Host last
        """)
        try folder.write("Host b\n", to: "conf.d/20-b.conf")
        try folder.write("Host a\n", to: "conf.d/10-a.conf")
        try folder.write("Host skipped\n", to: "conf.d/notes.txt")
        try folder.write("Host extra\n", to: "extra")
        try folder.write("Host spaced\n", to: "with space")
        #expect(folder.load().map(\.alias) == ["first", "a", "b", "extra", "spaced", "last"])
    }

    @Test
    func an_included_file_starts_in_the_block_of_its_include() throws {
        let folder = try Folder()
        try folder.write("""
        Host devbox
            Include devbox.conf
            User outer
        Host web
        """)
        try folder.write("""
        HostName devbox.example.com
        Host inner
            User inner
        """, to: "devbox.conf")
        #expect(folder.load() == [
            SSHConfigHost(alias: "devbox", hostName: "devbox.example.com", user: "outer"),
            SSHConfigHost(alias: "inner", hostName: nil, user: "inner"),
            SSHConfigHost(alias: "web", hostName: nil, user: nil),
        ])
    }

    @Test
    func an_include_loop_stops_at_the_depth_limit() throws {
        let folder = try Folder()
        try folder.write("""
        Host loop
        Include config
        """)
        #expect(folder.load().map(\.alias) == ["loop"])
    }

    @Test
    func a_missing_file_gives_no_hosts() throws {
        let folder = try Folder()
        #expect(folder.load().isEmpty)
        try folder.write("Include nowhere/*\nHost box\n")
        #expect(folder.load().map(\.alias) == ["box"])
    }

    @Test
    func tokens_read_equals_signs_quotes_and_case() {
        #expect(SSHConfigHosts.tokens("  HostName=devbox") ?? ("", []) == ("hostname", ["devbox"]))
        #expect(SSHConfigHosts.tokens("User = me") ?? ("", []) == ("user", ["me"]))
        #expect(SSHConfigHosts.tokens("Host a\tb  \"c d\"") ?? ("", []) == ("host", ["a", "b", "c d"]))
        #expect(SSHConfigHosts.tokens("# Host a") == nil)
        #expect(SSHConfigHosts.tokens("   ") == nil)
    }

    @Test
    func detail_says_where_the_alias_goes() {
        #expect(SSHConfigHost(alias: "a", hostName: "a.example.com", user: "me").detail == "me@a.example.com")
        #expect(SSHConfigHost(alias: "a", hostName: "a.example.com", user: nil).detail == "a.example.com")
        #expect(SSHConfigHost(alias: "a", hostName: "a", user: nil).detail == nil)
        #expect(SSHConfigHost(alias: "a", hostName: nil, user: "me").detail == "me@a")
        #expect(SSHConfigHost(alias: "a", hostName: nil, user: nil).detail == nil)
    }
}
