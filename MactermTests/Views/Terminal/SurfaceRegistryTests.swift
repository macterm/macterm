import Foundation
@testable import Macterm
import Testing

@MainActor
struct SurfaceRegistryTests {
    private let registry = SurfaceRegistry.shared

    private func makePane() -> Pane {
        Pane(projectPath: "/tmp", projectID: UUID())
    }

    @Test
    func a_pane_has_one_incubator_surface_until_a_host_draws_it() {
        let pane = makePane()
        let surfaces = registry.surfaces(of: pane)
        #expect(surfaces.count == 1)
        #expect(surfaces[0].host == .incubator)
        #expect(registry.surface(for: pane, in: .incubator) === surfaces[0])
    }

    @Test
    func the_first_host_takes_the_incubator_surface() {
        let pane = makePane()
        let warm = registry.surface(for: pane, in: .incubator)
        let quick = registry.surface(for: pane, in: .quickTerminal)
        #expect(quick === warm)
        #expect(quick.host == .quickTerminal)
        #expect(registry.surfaces(of: pane).count == 1)
    }

    @Test
    func each_window_gets_its_own_surface() {
        let pane = makePane()
        let a = UUID(), b = UUID()
        let forA = registry.surface(for: pane, in: .window(a))
        let forB = registry.surface(for: pane, in: .window(b))
        #expect(forA !== forB)
        #expect(registry.surface(for: pane, in: .window(a)) === forA)
        #expect(registry.surface(for: pane, in: .incubator) === forA, "the incubator gets the first surface")
    }

    @Test
    func existingSurface_makes_nothing() {
        let pane = makePane()
        #expect(registry.existingSurface(for: pane, in: .window(UUID())) == nil)
        #expect(registry.existingSurface(for: pane, in: .incubator) == nil)
        _ = registry.surfaces(of: pane)
        #expect(registry.existingSurface(for: pane, in: .widget(UUID())) == nil)
        #expect(registry.surfaces(of: pane).count == 1)
    }

    @Test
    func a_released_window_gives_the_last_surface_back_to_the_incubator() {
        let pane = makePane()
        let a = UUID()
        let surface = registry.surface(for: pane, in: .window(a))
        registry.releaseSurfaces(ofWindow: a)
        #expect(registry.surfaces(of: pane).count == 1)
        #expect(surface.host == .incubator)
    }

    @Test
    func a_retired_surface_leaves_the_next_one() {
        let pane = makePane()
        let forA = registry.surface(for: pane, in: .window(UUID()))
        let forB = registry.surface(for: pane, in: .window(UUID()))
        registry.retire(forA)
        #expect(registry.surfaces(of: pane).count == 1)
        #expect(registry.surfaces(of: pane).first === forB)
        registry.retire(forB)
        #expect(registry.surfaces(of: pane).count == 1, "a pane keeps its last surface")
    }

    @Test
    func the_surfaces_of_a_released_pane_go() {
        weak var released: PaneSurface?
        do {
            let pane = makePane()
            released = registry.surface(for: pane, in: .window(UUID()))
            #expect(released != nil)
        }
        // A teardown of another pane drops the entries of panes that are gone.
        registry.destroySurfaces(of: makePane())
        #expect(released == nil)
    }

    @Test
    func a_view_types_the_command_only_on_its_first_build() {
        let pane = Pane(projectPath: "/tmp", projectID: UUID(), start: .typed("echo hi"))
        let first = registry.makeView(for: pane)
        let second = registry.makeView(for: pane)
        #expect(first.start == .typed("echo hi"))
        #expect(second.start == nil)
    }
}
