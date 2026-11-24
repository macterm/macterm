@testable import Macterm
import Testing

/// The one notice of the palette's results (`PaletteNotice.resolve`): which
/// message shows, and that two never show together.
struct PaletteNoticeTests {
    private let failure = PaletteFailure(title: "Cannot list Pods", detail: "kubectl: not found")
    private let refusal = PaletteFailure(title: "There is no path ~/none on devbox.", retryable: false)
    private let loading = PaletteLoading(message: "Connecting to devbox…")

    private func notice(
        failure: PaletteFailure? = nil,
        loading: PaletteLoading? = nil,
        hasRows: Bool = false,
        isInput: Bool = false,
        queryIsEmpty: Bool = false
    ) -> PaletteNotice? {
        PaletteNotice.resolve(failure: failure, loading: loading, hasRows: hasRows, isInput: isInput, queryIsEmpty: queryIsEmpty)
    }

    @Test
    func a_failure_shows_with_or_without_rows_and_wins_over_loading() {
        #expect(notice(failure: failure) == .failure(failure))
        #expect(notice(failure: failure, hasRows: true) == .failure(failure), "above rows an earlier listing left")
        #expect(notice(failure: failure, loading: loading) == .failure(failure))
    }

    @Test
    func a_refusal_is_the_same_notice_on_an_input_screen() {
        #expect(notice(failure: refusal, isInput: true) == .failure(refusal))
        #expect(notice(failure: refusal, hasRows: true, isInput: true) == .failure(refusal), "above the completions")
    }

    @Test
    func loading_shows_only_with_no_rows() {
        #expect(notice(loading: loading) == .loading(loading))
        #expect(notice(loading: loading, isInput: true) == .loading(loading), "an input screen's check")
        #expect(notice(loading: loading, hasRows: true) == nil, "the field's spinner shows it")
    }

    @Test
    func no_matches_is_for_a_search_only() {
        #expect(notice() == .noMatches)
        #expect(notice(hasRows: true) == nil)
        #expect(notice(queryIsEmpty: true) == nil)
        #expect(notice(isInput: true) == nil, "an input field is a value, not a search")
    }
}
