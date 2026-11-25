import AppKit
@testable import Macterm
import SwiftUI
import Testing
import UniformTypeIdentifiers

@MainActor
struct SidebarDragFeedbackTests {
    /// Two sidebar Lists in one window, as the native sidebar and the overlay
    /// sidebar are. Only the List with the probe gets the gap. The other List
    /// keeps the default insertion line.
    @Test
    func only_the_list_with_the_probe_gets_the_gap_feedback() async throws {
        let guarded = GuardFlag()
        let content = HStack(spacing: 0) {
            sidebarList().background {
                SidebarDragFeedback(isGuarded: Binding(get: { guarded.value }, set: { guarded.value = $0 }))
            }
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
        // The List adds the project drop slots only when it knows that the
        // guard is on.
        #expect(await poll { guarded.value ? true : nil } == true)
    }

    @Test
    func a_frame_that_no_outline_covers_finds_nothing() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        #expect(SidebarDragFeedback.ProbeView.outline(at: NSRect(x: 0, y: 0, width: 50, height: 50), in: root) == nil)
        #expect(SidebarDragFeedback.ProbeView.outline(at: .zero, in: root) == nil)
    }

    /// A drag across a section, out of the outline view (as onto a project
    /// header with its own drop destination), back in, and a drop. Without
    /// `OutlineGapDropGuard`, the exit crashes the test process in SwiftUI.
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
        .background { SidebarDragFeedback(isGuarded: .constant(false)) }
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
        #expect(drops.entries.isEmpty)
        // Back in, above A1, and drop.
        drag.location = point(row: 2, fraction: 0.2)
        #expect(!outline.draggingEntered(drag).isEmpty)
        #expect(outline.prepareForDragOperation(drag))
        #expect(outline.performDragOperation(drag))
        outline.concludeDragOperation(drag)

        let log = await poll { drops.entries.isEmpty ? nil : drops.entries }
        #expect(log == ["A [\"A1\"] 1"])
    }

    /// A project drag opens its gap at the project slot nearest to the
    /// pointer, and the drop lands at that slot. The rows: A (A0, A1),
    /// B (B0, B.x (Bx0), B.y), C, D (D0, D.e), and scratch rows S0 and S1, as
    /// the sidebar has them. B.y, C and D.e have no rows. The scratch
    /// `ForEach` takes a project at its first slot, as with the gap guard in
    /// the app. The test calls the outline view, so the header rows
    /// do not take the drag here as their own drop views do in the app.
    @Test
    func a_project_drag_drops_at_the_slot_of_its_gap() async throws {
        let drops = DropLog()
        let tree = [
            ProbeNode(name: "A", tabs: ["A0", "A1"], children: []),
            ProbeNode(name: "B", tabs: ["B0"], children: [
                ProbeNode(name: "B.x", tabs: ["Bx0"], children: []),
                ProbeNode(name: "B.y", tabs: [], children: []),
            ]),
            ProbeNode(name: "C", tabs: [], children: []),
            ProbeNode(name: "D", tabs: ["D0"], children: [ProbeNode(name: "D.e", tabs: [], children: [])]),
        ]
        let projectType = NSPasteboard.PasteboardType(UTType.mactermProject.identifier)
        let content = List {
            ForEach(tree) { ProbeProjectRow(node: $0, drops: drops) }
                .dropDestination(for: MovableProject.self) { _, offset in
                    drops.entries.append("top \(offset)")
                }
            ForEach(["S0", "S1"], id: \.self) { Text($0) }
                .dropDestination(for: MovableProject.self) { _, offset in
                    drops.entries.append("scratch \(offset)")
                }
        }
        .listStyle(.sidebar)
        .background { SidebarDragFeedback(branchTypes: [projectType], isGuarded: .constant(false)) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: content)
        window.layoutIfNeeded()

        // Rows: 0 A, 1 A0, 2 A1, 3 B, 4 B0, 5 B.x, 6 Bx0, 7 B.y, 8 C, 9 D,
        // 10 D0, 11 D.e, 12 S0, 13 S1.
        let outline = try #require(await poll {
            window.contentView.flatMap { Self.outlines(in: $0).first }.flatMap {
                $0.draggingDestinationFeedbackStyle == .gap && $0.numberOfRows == 14 ? $0 : nil
            }
        })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macterm-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try pasteboard.setData(JSONEncoder().encode(MovableProject(projectID: UUID())), forType: projectType)

        func drop(row: Int, fraction: CGFloat) async -> [String] {
            drops.entries = []
            let rect = outline.rect(ofRow: row)
            let location = outline.convert(NSPoint(x: rect.midX, y: rect.minY + rect.height * fraction), to: nil)
            let drag = FakeDrag(location: location, pasteboard: pasteboard, window: window)
            _ = outline.draggingEntered(drag)
            _ = outline.draggingUpdated(drag)
            guard outline.prepareForDragOperation(drag), outline.performDragOperation(drag) else {
                outline.draggingExited(drag)
                return []
            }
            outline.concludeDragOperation(drag)
            return await poll { drops.entries.isEmpty ? nil : drops.entries } ?? []
        }

        // On A's tabs (A has no projects inside): the nearer of the slots
        // before A and after A.
        #expect(await drop(row: 1, fraction: 0.2) == ["top 0"])
        #expect(await drop(row: 2, fraction: 0.5) == ["top 1"])
        // On the upper half of B's row: before B, the same slot.
        #expect(await drop(row: 3, fraction: 0.1) == ["top 1"])
        // On B's tab: inside B, before its first project, which is nearer
        // than the slot before B.
        #expect(await drop(row: 4, fraction: 0.5) == ["into B 0"])
        // On the tab of B.x: after B.x, inside B.
        #expect(await drop(row: 6, fraction: 0.5) == ["into B 1"])
        // On the upper half of C's row: before C.
        #expect(await drop(row: 8, fraction: 0.1) == ["top 2"])
        // Below B.y and below C, which have no rows (no crash): after them.
        #expect(await drop(row: 7, fraction: 0.9) == ["into B 2"])
        #expect(await drop(row: 8, fraction: 0.9) == ["top 3"])
        // On D's tab, where the only project inside has no rows: inside D.
        #expect(await drop(row: 10, fraction: 0.5) == ["into D 0"])
        #expect(await drop(row: 11, fraction: 0.9) == ["into D 1"])
        // On the scratch rows: the slot after the last project, which is
        // the first slot of the scratch rows.
        #expect(await drop(row: 12, fraction: 0.5) == ["scratch 0"])
        #expect(await drop(row: 13, fraction: 0.9) == ["scratch 0"])
    }

    /// A held drag opens a closed project while the gap is open (the
    /// spring-open of a project header), and closes it again. SwiftUI then
    /// adds and removes rows in the middle of the drag, and the drop changes
    /// rows too. Without the row-update part of `OutlineGapDropGuard`, AppKit
    /// raises "Setting the gap row (index -1) while updating" and the test
    /// process stops.
    @Test
    func a_project_that_opens_during_a_drag_keeps_the_gap_and_the_drop() async throws {
        let drops = DropLog()
        let expansion = ProbeExpansion(open: ["B"])
        let tree = [
            ProbeNode(name: "A", tabs: ["A0"], children: []),
            ProbeNode(name: "B", tabs: ["B0", "B1"], children: [
                ProbeNode(name: "B.x", tabs: ["Bx0"], children: []),
                ProbeNode(name: "B.y", tabs: [], children: []),
            ]),
            ProbeNode(name: "C", tabs: ["C0"], children: []),
        ]
        let projectType = NSPasteboard.PasteboardType(UTType.mactermProject.identifier)
        let content = List {
            ForEach(tree) { ProbeProjectRow(node: $0, drops: drops, expansion: expansion) }
                .dropDestination(for: MovableProject.self) { _, offset in
                    drops.entries.append("top \(offset)")
                }
        }
        .listStyle(.sidebar)
        .background { SidebarDragFeedback(branchTypes: [projectType], isGuarded: .constant(false)) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: content)
        window.layoutIfNeeded()

        // Rows: 0 A, 1 B, 2 B0, 3 B1, 4 B.x (closed), 5 B.y, 6 C.
        let outline = try #require(await poll {
            window.contentView.flatMap { Self.outlines(in: $0).first }.flatMap {
                $0.draggingDestinationFeedbackStyle == .gap && $0.numberOfRows == 7 ? $0 : nil
            }
        })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macterm-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try pasteboard.setData(JSONEncoder().encode(MovableProject(projectID: UUID())), forType: projectType)
        func point(row: Int, fraction: CGFloat) -> NSPoint {
            let rect = outline.rect(ofRow: row)
            return outline.convert(NSPoint(x: rect.midX, y: rect.minY + rect.height * fraction), to: nil)
        }

        // On the line between B.x and B.y: the gap opens after B.x.
        let drag = FakeDrag(location: point(row: 4, fraction: 0.9), pasteboard: pasteboard, window: window)
        #expect(!outline.draggingEntered(drag).isEmpty)
        // B.x opens under the held drag: rows are added.
        expansion.open.insert("B.x")
        #expect(await poll { outline.numberOfRows == 8 ? true : nil } == true)
        // The next drag update opens the gap again, after B.x and its tab.
        // A pointer that does not move keeps it there.
        drag.location = point(row: 5, fraction: 0.9)
        #expect(!outline.draggingUpdated(drag).isEmpty)
        #expect(!outline.draggingUpdated(drag).isEmpty)
        // B.x closes under the held drag: rows are removed. The pointer is
        // held still, and the guard opens the gap again after the update.
        drag.location = point(row: 4, fraction: 0.9)
        expansion.open.remove("B.x")
        #expect(await poll { outline.numberOfRows == 7 ? true : nil } == true)
        #expect(await poll { outline.draggingUpdated(drag).isEmpty ? nil : true } == true)
        // The drop changes rows at once: B.x opens again.
        drops.afterDrop = { expansion.open.insert("B.x") }
        #expect(outline.prepareForDragOperation(drag))
        #expect(outline.performDragOperation(drag))
        outline.concludeDragOperation(drag)
        let log = await poll { drops.entries.isEmpty ? nil : drops.entries }
        #expect(log == ["into B 1"])
        #expect(await poll { outline.numberOfRows == 8 ? true : nil } == true)
        // After the drop, a row update does not run the drag again.
        let reads = drag.locationReads
        expansion.open.remove("B")
        #expect(await poll { outline.numberOfRows == 3 ? true : nil } == true)
        #expect(drag.locationReads == reads)
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

private struct ProbeNode: Identifiable {
    let name: String
    let tabs: [String]
    let children: [ProbeNode]
    var id: String { name }
}

/// A project row of the sidebar's shape: its tabs, then the projects inside
/// it. Only a `ForEach` with rows has a drop destination, as in the app.
private struct ProbeProjectRow: View {
    let node: ProbeNode
    let drops: DropLog
    /// The open projects. Nil: every project is open.
    var expansion: ProbeExpansion?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expansion?.open.contains(node.name) ?? true },
            set: { isOpen in
                if isOpen { expansion?.open.insert(node.name) } else { expansion?.open.remove(node.name) }
            }
        )) {
            if node.tabs.isEmpty {
                ForEach(node.tabs, id: \.self) { Text($0) }
            } else {
                ForEach(node.tabs, id: \.self) { Text($0) }
                    .dropDestination(for: MovableTab.self) { _, offset in
                        drops.entries.append("tab \(node.name) \(offset)")
                    }
            }
            if node.children.isEmpty {
                ForEach(node.children) { ProbeProjectRow(node: $0, drops: drops, expansion: expansion) }
            } else {
                ForEach(node.children) { ProbeProjectRow(node: $0, drops: drops, expansion: expansion) }
                    .dropDestination(for: MovableProject.self) { _, offset in
                        drops.entries.append("into \(node.name) \(offset)")
                        drops.afterDrop?()
                    }
            }
        } label: {
            Text(node.name)
        }
    }
}

@MainActor @Observable
private final class ProbeExpansion {
    var open: Set<String>
    init(open: Set<String>) {
        self.open = open
    }
}

@MainActor
private final class GuardFlag {
    var value = false
}

@MainActor
private final class DropLog {
    var entries: [String] = []
    /// Runs in the drop handler, after the entry.
    var afterDrop: (() -> Void)?
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
    /// The number of reads of `draggingLocation`: AppKit reads it at each
    /// drag update.
    private(set) var locationReads = 0
    var draggingLocation: NSPoint {
        locationReads += 1
        return location
    }

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
