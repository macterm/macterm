import AppKit
@testable import Macterm
import Testing

@MainActor
struct WindowRegistryTests {
    @Test
    func the_first_state_proposed_for_a_window_wins() {
        let registry = WindowRegistry()
        let window = NSWindow()
        let first = WindowState()
        let (adopted, isNew) = registry.adopt(first, for: window)
        #expect(adopted === first)
        #expect(isNew)
        let (again, isNewAgain) = registry.adopt(WindowState(), for: window)
        #expect(again === first)
        #expect(!isNewAgain)
        #expect(registry.nsWindow(for: first) === window)
        #expect(registry.forget(window) === first)
        #expect(registry.state(for: window) == nil)
    }

    @Test
    func the_key_window_falls_back_to_the_first() {
        let registry = WindowRegistry()
        let a = WindowState(), b = WindowState()
        registry.append(a)
        registry.append(b)
        registry.append(a)
        #expect(registry.windows.count == 2, "a window is listed once")
        #expect(registry.keyWindow == nil)
        #expect(registry.keyOrFirstWindow === a)
        registry.setKeyWindowID(b.id)
        #expect(registry.keyWindow === b)
        registry.remove(b)
        #expect(registry.keyWindow == nil)
        #expect(registry.keyOrFirstWindow === a)
    }
}
