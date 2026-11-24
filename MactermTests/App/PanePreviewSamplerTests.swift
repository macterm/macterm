import Foundation
@testable import Macterm
import Testing

@MainActor
struct PanePreviewSamplerTests {
    /// Two clients that show one pane: the renderer stays awake until the
    /// last of them ends, and no timer runs after that.
    @Test
    func a_pane_that_two_clients_show_stays_awake_until_the_last_ends() {
        let sampler = PanePreviewSampler()
        let shared = Pane(projectPath: "/p", projectID: UUID())
        let only = Pane(projectPath: "/p", projectID: UUID())
        let sharedView = SurfaceRegistry.shared.ensureView(of: shared)
        let onlyView = SurfaceRegistry.shared.ensureView(of: only)
        let window = PanePreviewSampler.Client.projectScreen(UUID())

        sampler.begin(.tabSwitcher, panes: [shared, only])
        sampler.begin(window, panes: [shared])
        #expect(sampler.isSampling)
        #expect(sharedView.rendersForPreview)
        #expect(onlyView.rendersForPreview)

        sampler.end(.tabSwitcher)
        #expect(sampler.isSampling)
        #expect(!sampler.isSampling(for: .tabSwitcher))
        #expect(sharedView.rendersForPreview)
        #expect(!onlyView.rendersForPreview)

        sampler.end(window)
        #expect(!sampler.isSampling)
        #expect(!sharedView.rendersForPreview)
    }

    /// A new `begin` for a client replaces its panes: a pane it no longer
    /// shows is parked at once.
    @Test
    func a_new_begin_replaces_the_panes_of_the_client() {
        let sampler = PanePreviewSampler()
        let first = Pane(projectPath: "/p", projectID: UUID())
        let second = Pane(projectPath: "/p", projectID: UUID())
        let firstView = SurfaceRegistry.shared.ensureView(of: first)
        let secondView = SurfaceRegistry.shared.ensureView(of: second)
        let window = PanePreviewSampler.Client.projectScreen(UUID())

        sampler.begin(window, panes: [first])
        sampler.begin(window, panes: [second])
        #expect(!firstView.rendersForPreview)
        #expect(secondView.rendersForPreview)

        sampler.end(window)
        #expect(!secondView.rendersForPreview)
        #expect(!sampler.isSampling)
    }

    /// A pane whose view did not exist at `begin` is woken at the next
    /// sample, when its view exists.
    @Test
    func a_pane_whose_view_comes_later_is_woken_at_the_next_sample() {
        let sampler = PanePreviewSampler()
        let pane = Pane(projectPath: "/p", projectID: UUID())
        let window = PanePreviewSampler.Client.projectScreen(UUID())

        sampler.begin(window, panes: [pane])
        let view = SurfaceRegistry.shared.ensureView(of: pane)
        #expect(!view.rendersForPreview)
        // A second `begin` samples at once, as a timer tick does.
        sampler.begin(window, panes: [pane])
        #expect(view.rendersForPreview)

        sampler.end(window)
        #expect(!view.rendersForPreview)
    }
}
