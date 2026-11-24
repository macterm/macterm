import AppKit
@testable import Macterm
import SwiftUI
import Testing

@MainActor
struct SidebarDragFeedbackTests {
    @Test
    func a_sidebar_list_with_the_probe_gets_the_gap_feedback() async throws {
        let list = List {
            Section {
                ForEach(0 ..< 3, id: \.self) { Text("row \($0)") }
            }
        }
        .listStyle(.sidebar)
        .background { SidebarDragFeedback() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: list)
        window.layoutIfNeeded()

        let outline = try #require(await poll { window.contentView?.firstDescendant(ofType: NSOutlineView.self) })
        // The style of a plain `.sidebar` List, before the probe acts on it,
        // is `.sourceList`: the insertion line.
        let style = await poll { outline.draggingDestinationFeedbackStyle == .gap ? true : nil }
        #expect(style == true)
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
