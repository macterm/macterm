import AppKit
@testable import Macterm
import SwiftUI
import Testing

@MainActor
struct SidebarDragFeedbackTests {
    /// Two sidebar Lists in one window, as the native sidebar and the overlay
    /// sidebar are. Only the List with the probe gets the gap; the other keeps
    /// the default insertion line.
    @Test
    func only_the_list_with_the_probe_gets_the_gap_feedback() async throws {
        let content = HStack(spacing: 0) {
            sidebarList().background { SidebarDragFeedback() }
            sidebarList()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: content)
        window.layoutIfNeeded()

        let outlines = try #require(await poll {
            let found = Self.outlines(in: window.contentView!)
            return found.count == 2 ? found : nil
        })
        let sorted = outlines.sorted {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        let probed = await poll { sorted[0].draggingDestinationFeedbackStyle == .gap ? true : nil }
        #expect(probed == true)
        #expect(sorted[1].draggingDestinationFeedbackStyle == .sourceList)
    }

    @Test
    func a_frame_that_no_outline_covers_finds_nothing() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        #expect(SidebarDragFeedback.ProbeView.outline(at: NSRect(x: 0, y: 0, width: 50, height: 50), in: root) == nil)
        #expect(SidebarDragFeedback.ProbeView.outline(at: .zero, in: root) == nil)
    }

    private func sidebarList() -> some View {
        List {
            Section {
                ForEach(0 ..< 3, id: \.self) { Text("row \($0)") }
            }
        }
        .listStyle(.sidebar)
    }

    private static func outlines(in view: NSView) -> [NSOutlineView] {
        (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap { outlines(in: $0) }
    }

    /// Polls until `read` gives a value, sleeping between tries, for up to
    /// two seconds.
    private func poll<Value>(_ read: () -> Value?) async -> Value? {
        for _ in 0 ..< 100 {
            if let value = read() { return value }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
