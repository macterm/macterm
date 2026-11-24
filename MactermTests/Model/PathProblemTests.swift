import Foundation
@testable import Macterm
import Testing

/// The one notice of a path that is not a folder (`PathProblem`, 0583).
struct PathProblemTests {
    @Test
    func the_notice_names_the_path_as_typed() {
        #expect(PathProblem.missing.notice(for: "~/work/api") == "Path ~/work/api doesn't exist")
        #expect(PathProblem.notDirectory.notice(for: "~/notes.txt") == "~/notes.txt is not a directory")
    }

    @Test
    func a_local_path_is_a_folder_a_file_or_missing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-path-problem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("notes.txt")
        try Data().write(to: file)

        #expect(PathProblem.local(atPath: root.path) == nil)
        #expect(PathProblem.local(atPath: "~") == nil, "a ~ expands")
        #expect(PathProblem.local(atPath: file.path) == .notDirectory)
        #expect(PathProblem.local(atPath: root.appendingPathComponent("none").path) == .missing)
        #expect(PathProblem.local(atPath: "relative/path") == .missing, "a relative path is never read against a working directory")
    }

    @Test
    func a_remote_folder_has_the_same_notice_as_a_local_one() {
        #expect(RemoteHosts.refusal(.exists, directory: "~/api", destination: "box") == nil)
        #expect(RemoteHosts.refusal(.missing, directory: "~/api", destination: "box") == "Path ~/api doesn't exist")
        #expect(RemoteHosts.refusal(.notDirectory, directory: "~/notes.txt", destination: "box") == "~/notes.txt is not a directory")
        #expect(RemoteHosts.refusal(.unreachable, directory: "~/api", destination: "box") == "Macterm cannot connect to box.")
    }
}
