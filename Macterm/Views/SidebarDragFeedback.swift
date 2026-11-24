import AppKit
import ObjectiveC
import os
import SwiftUI

private let logger = Logger(subsystem: appBundleID, category: "SidebarDragFeedback")

/// Sets the drop feedback of the sidebar's outline view to `.gap`. During a
/// drag, the rows below the drop slot move apart and an empty slot opens.
/// The Finder sidebar does this. The default of a `.sidebar` List is
/// `.sourceList`, which draws an insertion line.
///
/// SwiftUI has no modifier for the style. This view is a `.background` of
/// the List, so it has the frame of the List. It finds the outline view whose
/// scroll view is at that frame and sets the style. A frame match, not the
/// nearest outline view: the overlay sidebar and the collapsed native sidebar
/// are in one window, and each has its own outline view.
///
/// The style is set only after `OutlineGapExitGuard` is in place. Without
/// the guard, a drag that leaves the outline view crashes SwiftUI.
///
/// The drop handlers do not change. The same `.dropDestination`s get the same
/// offsets. A folder from Finder shows no gap, because
/// `SidebarFolderDropTarget` takes that drag above the outline view.
struct SidebarDragFeedback: NSViewRepresentable {
    func makeNSView(context _: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ view: ProbeView, context _: Context) {
        view.scheduleApply()
    }

    final class ProbeView: NSView {
        /// The outline view that has the style. When SwiftUI replaces it,
        /// the next pass finds the new one.
        private weak var outline: NSOutlineView?
        private var isScheduled = false
        /// Passes left before the probe stops a search that finds nothing.
        private var triesLeft = 0
        private static let maxTries = 20

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
        }

        override func layout() {
            super.layout()
            scheduleApply()
        }

        /// One pass on the next turn of the run loop, after SwiftUI puts the
        /// outline view in the window. Calls before the pass join it.
        func scheduleApply() {
            if outline?.window != nil, outline?.window == window { return }
            triesLeft = Self.maxTries
            guard !isScheduled else { return }
            isScheduled = true
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            isScheduled = false
            guard let window, let root = window.contentView else { return }
            let frame = convert(bounds, to: nil)
            if let found = Self.outline(at: frame, in: root) {
                outline = found
                guard OutlineGapExitGuard.install(on: found) else {
                    // Fail closed: the insertion line stays.
                    logger.error("no drop gap: the outline view's data source has no validateDrop method")
                    return
                }
                if found.draggingDestinationFeedbackStyle != .gap {
                    found.draggingDestinationFeedbackStyle = .gap
                }
                return
            }
            // SwiftUI has not made the outline view yet: try again a little
            // later, a limited number of times.
            triesLeft -= 1
            guard triesLeft > 0 else { return }
            isScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.apply() }
        }

        /// The outline view whose scroll view covers most of `frame` (window
        /// coordinates), when the two overlap by more than half. The insets
        /// of the List (the pin drop zone, the footer) can make the two
        /// frames differ a little. A collapsed sidebar has no overlap.
        static func outline(at frame: NSRect, in root: NSView) -> NSOutlineView? {
            guard frame.width > 0, frame.height > 0 else { return nil }
            var best: (outline: NSOutlineView, overlap: CGFloat)?
            visit(root) { view in
                guard let candidate = view as? NSOutlineView,
                      let scroll = candidate.enclosingScrollView
                else { return }
                let shared = scroll.convert(scroll.bounds, to: nil).intersection(frame)
                guard !shared.isNull else { return }
                let overlap = (shared.width * shared.height) / (frame.width * frame.height)
                if overlap > 0.5, overlap > best?.overlap ?? 0 {
                    best = (candidate, overlap)
                }
            }
            return best?.outline
        }

        private static func visit(_ view: NSView, _ body: (NSView) -> Void) {
            body(view)
            for subview in view.subviews {
                visit(subview, body)
            }
        }
    }
}

/// Keeps SwiftUI's outline list alive when a drag leaves an outline view
/// whose drop feedback is `.gap`.
///
/// In the gap style, `NSOutlineView.draggingExited` validates one more drop,
/// with no item and the child index -2, to close the gap. SwiftUI's data
/// source reads its rows at that index and stops the app ("index -2 out of
/// bounds", ui-review 0573). A drag leaves the outline view each time it
/// goes onto a row that has its own `.dropDestination`, such as a project
/// header. The regular style never makes this call.
///
/// The guard replaces the data source's `validateDrop` method. For a child
/// index below `NSOutlineViewDropOnItemIndex` on an outline view in the gap
/// style, it answers "no drop" and does not call SwiftUI. Every other call
/// goes to SwiftUI unchanged. Measured in a standalone program with a fake
/// drag: the exit no longer stops, the gap closes, a new drag opens the gap
/// again, and the drop lands at its slot.
@MainActor
enum OutlineGapExitGuard {
    private typealias Validate = @convention(c) (
        AnyObject, Selector, NSOutlineView, NSDraggingInfo, AnyObject?, Int
    ) -> NSDragOperation

    /// The classes that have the guard.
    private static var guardedClasses: Set<ObjectIdentifier> = []

    /// Installs the guard on the class of the outline view's data source,
    /// one time for each class. False when the class has no `validateDrop`
    /// method: then the outline view must keep its default style.
    static func install(on outline: NSOutlineView) -> Bool {
        guard let source = outline.dataSource, let dataSourceClass = object_getClass(source) else { return false }
        let key = ObjectIdentifier(dataSourceClass)
        if guardedClasses.contains(key) { return true }
        let selector = #selector(NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:))
        guard let method = class_getInstanceMethod(dataSourceClass, selector) else { return false }
        let original = unsafeBitCast(method_getImplementation(method), to: Validate.self)
        let replacement: @convention(block) (AnyObject, NSOutlineView, NSDraggingInfo, AnyObject?, Int)
            -> NSDragOperation = { source, view, info, item, index in
                let isGapExit = MainActor.assumeIsolated {
                    index < NSOutlineViewDropOnItemIndex && view.draggingDestinationFeedbackStyle == .gap
                }
                if isGapExit { return [] }
                return original(source, selector, view, info, item, index)
            }
        // A method that the class only inherits gets its own copy first, so
        // that the superclass keeps its own method.
        let types = method_getTypeEncoding(method)
        let block = imp_implementationWithBlock(replacement)
        if !class_addMethod(dataSourceClass, selector, block, types) {
            method_setImplementation(method, block)
        }
        guardedClasses.insert(key)
        return true
    }
}
