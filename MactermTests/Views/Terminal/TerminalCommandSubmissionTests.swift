@testable import Macterm
import Testing

struct TerminalCommandSubmissionTests {
    @Test
    func returnAndKeypadEnterAreSubmissions() {
        #expect(TerminalCommandSubmission.isReturn(
            keyCode: 36, isRepeat: false, hasMarkedText: false, hasUserModifiers: false
        ))
        #expect(TerminalCommandSubmission.isReturn(
            keyCode: 76, isRepeat: false, hasMarkedText: false, hasUserModifiers: false
        ))
    }

    @Test(arguments: [
        (36, true, false, false),
        (36, false, true, false),
        (36, false, false, true),
        (49, false, false, false),
    ])
    func rejectsRepeatCompositionModifiersAndOtherKeys(
        keyCode: Int,
        isRepeat: Bool,
        hasMarkedText: Bool,
        hasUserModifiers: Bool
    ) {
        #expect(!TerminalCommandSubmission.isReturn(
            keyCode: UInt16(keyCode),
            isRepeat: isRepeat,
            hasMarkedText: hasMarkedText,
            hasUserModifiers: hasUserModifiers
        ))
    }

    @Test
    func programmaticTextRequiresNewline() {
        #expect(TerminalCommandSubmission.textContainsNewline("sleep 1\n"))
        #expect(TerminalCommandSubmission.textContainsNewline("sleep 1\r"))
        #expect(!TerminalCommandSubmission.textContainsNewline("sleep 1"))
    }

    /// `TerminalCommandSubmission` carries its own key codes (it stays free of
    /// actor isolation, so it can't read the `@MainActor` registry at runtime).
    /// Pin them to that shared vocabulary here so the two can't drift.
    @Test @MainActor
    func keyCodesMatchHotkeyRegistry() throws {
        func code(_ token: String) throws -> UInt16 {
            try #require(HotkeyRegistry.keyCode(forToken: token))
        }

        #expect(try TerminalCommandSubmission.isReturn(
            keyCode: code("return"), isRepeat: false, hasMarkedText: false, hasUserModifiers: false
        ))
    }
}
