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

    /// A drag across a section, out of the outline view (as onto a project
    /// header with its own drop destination), back in, and a drop. Without
    /// `OutlineGapExitGuard`, the exit stops the test process in SwiftUI
    /// (ui-review 0573).
    @Test
    func a_drag_that_leaves_the_gap_outline_and_comes_back_drops_at_its_slot() async throws {
        let drops = DropLog()
        let content = List {
            ForEach(["A", "B"], id: \.self) { key in
                DisclosureGroup(isExpanded: .constant(true)) {
                    ForEach(["\(key)0", "\(key)1"], id: \.self) { Text($0) }
                        .dropDestination(for: String.self) { items, offset in
                            drops.entries.append("\(key) \(items) \(offset)")
                        }
                } label: {
                    Text(key).dropDestination(for: String.self) { _, _ in true }
                }
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
        window.contentView = NSHostingView(rootView: content)
        window.layoutIfNeeded()

        let outline = try #require(await poll {
            window.contentView.flatMap { Self.outlines(in: $0).first }.flatMap {
                $0.draggingDestinationFeedbackStyle == .gap && $0.numberOfRows == 6 ? $0 : nil
            }
        })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macterm-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("A1", forType: .string)
        func point(row: Int, fraction: CGFloat) -> NSPoint {
            let rect = outline.rect(ofRow: row)
            return outline.convert(NSPoint(x: rect.midX, y: rect.minY + rect.height * fraction), to: nil)
        }
        let drag = FakeDrag(location: point(row: 1, fraction: 0.2), pasteboard: pasteboard, window: window)

        #expect(!outline.draggingEntered(drag).isEmpty)
        // Into the rows of section B (rows: A, A0, A1, B, B0, B1).
        drag.location = point(row: 4, fraction: 0.8)
        #expect(!outline.draggingUpdated(drag).isEmpty)
        outline.draggingExited(drag)
        // Back in, above A1, and drop.
        drag.location = point(row: 2, fraction: 0.2)
        #expect(!outline.draggingEntered(drag).isEmpty)
        #expect(outline.prepareForDragOperation(drag))
        #expect(outline.performDragOperation(drag))
        outline.concludeDragOperation(drag)

        let log = await poll { drops.entries.isEmpty ? nil : drops.entries }
        #expect(log == ["A [\"A1\"] 1"])
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

@MainActor
private final class DropLog {
    var entries: [String] = []
}

/// A drag that the test moves by hand. AppKit reads only the location, the
/// pasteboard, the window and the operation mask from it here.
private final class FakeDrag: NSObject, NSDraggingInfo {
    var location: NSPoint
    let pasteboard: NSPasteboard
    weak var window: NSWindow?

    init(location: NSPoint, pasteboard: NSPasteboard, window: NSWindow) {
        self.location = location
        self.pasteboard = pasteboard
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy, .generic] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to _: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions = [],
        for _: NSView?,
        classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
