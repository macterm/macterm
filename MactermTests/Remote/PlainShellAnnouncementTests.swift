import Foundation
@testable import Macterm
import Testing

struct PlainShellAnnouncementTests {
    private func feed(_ chunks: [String]) -> (shown: String, pid: Int32?) {
        var announcement = PlainShellAnnouncement()
        var shown = Data()
        for chunk in chunks {
            shown += announcement.consume(Data(chunk.utf8))
        }
        return (String(decoding: shown, as: UTF8.self), announcement.pid)
    }

    private let osc = "\u{1B}]7701;shell="

    @Test
    func the_announcement_gives_the_pid_and_shows_nothing() {
        let result = feed([osc + "4242\u{07}$ "])
        #expect(result.pid == 4242)
        #expect(result.shown == "$ ")
    }

    @Test
    func an_announcement_split_across_reads_is_held_until_it_ends() {
        let bytes = Array(("x" + osc + "4242\u{07}$ ").utf8)
        for cut in 1 ..< bytes.count {
            let first = String(decoding: bytes[..<cut], as: UTF8.self)
            let second = String(decoding: bytes[cut...], as: UTF8.self)
            let result = feed([first, second])
            #expect(result.pid == 4242, "cut \(cut)")
            #expect(result.shown == "x$ ", "cut \(cut)")
        }
    }

    @Test
    func only_the_first_announcement_counts() {
        let result = feed([osc + "4242\u{07}", "ls\r\n" + osc + "1\u{07}"])
        #expect(result.pid == 4242)
        #expect(result.shown == "ls\r\n" + osc + "1\u{07}")
    }

    @Test
    func a_bad_pid_gives_none() {
        #expect(feed([osc + "12ab\u{07}$ "]).pid == nil)
        #expect(feed([osc + "1\u{07}$ "]).pid == nil)
        let long = feed([osc + "12345678901234\u{07}$ "])
        #expect(long.pid == nil)
        #expect(long.shown == "$ ")
    }

    @Test
    func output_with_no_announcement_passes_at_once() {
        // Only a tail that can start the marker waits for the next read.
        let result = feed(["login\r\n", "$ \u{1B}"])
        #expect(result.shown == "login\r\n$ ")
        #expect(result.pid == nil)
        let late = feed([String(repeating: "a", count: PlainShellAnnouncement.limit), osc + "7\u{07}"])
        #expect(late.pid == nil)
        #expect(late.shown.hasSuffix(osc + "7\u{07}"))
    }
}
