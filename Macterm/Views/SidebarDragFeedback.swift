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
/// scroll view is at that frame and sets the style. It matches by frame and
/// does not take the nearest outline view, because the overlay sidebar and
/// the collapsed native sidebar are in one window. Each of them has its own
/// outline view.
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
        /// False when the guard cannot go on the outline view's data source.
        /// Then the outline view keeps its default style.
        private var gapIsAllowed = false
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

        /// Schedules one pass on the next turn of the run loop, after SwiftUI
        /// puts the outline view in the window. More calls before the pass
        /// do not add passes. A probe with no size (the collapsed sidebar)
        /// does no search.
        func scheduleApply() {
            if let outline, outline.window != nil, outline.window == window {
                // Cheap: SwiftUI can set the style back.
                if gapIsAllowed, outline.draggingDestinationFeedbackStyle != .gap {
                    outline.draggingDestinationFeedbackStyle = .gap
                }
                return
            }
            guard bounds.width > 0, bounds.height > 0 else { return }
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
                switch OutlineGapExitGuard.install(on: found) {
                case .installed:
                    outline = found
                    gapIsAllowed = true
                    if found.draggingDestinationFeedbackStyle != .gap {
                        found.draggingDestinationFeedbackStyle = .gap
                    }
                    return
                case .unsupported:
                    // Fail closed: the insertion line stays, and no later
                    // pass tries again.
                    outline = found
                    gapIsAllowed = false
                    logger.error("no drop gap: the data source of the outline view has no validateDrop method")
                    return
                case .noDataSource:
                    break
                }
            }
            // SwiftUI has not made the outline view or its data source yet.
            // Try again a little later, a limited number of times.
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

/// Prevents a SwiftUI crash when a drag leaves an outline view whose drop
/// feedback is `.gap`. Never set `.gap` on a SwiftUI outline view without it.
///
/// In the gap style, `NSOutlineView.draggingExited` validates one more drop
/// to close the gap. That call has no item and the child index -2. SwiftUI's
/// data source reads its rows at that index, and the app crashes with
/// "index -2 out of bounds". A drag leaves the outline view each time that
/// it goes onto a row with its own `.dropDestination`, for example a project
/// header. The regular style does not make this call.
///
/// The guard replaces the `validateDrop` method of the data source class.
/// For a child index below `NSOutlineViewDropOnItemIndex` on an outline view
/// in the gap style, it returns "no drop" and does not call SwiftUI. All
/// other calls go to SwiftUI with no change. Other Lists keep the default
/// style, so the guard does not touch their drags.
///
/// Measured with a fake drag on a hosted List (`SidebarDragFeedbackTests`):
/// without the guard, the exit crashes. With it, the gap closes, a new drag
/// opens the gap again, and the drop lands at its slot.
@MainActor
enum OutlineGapExitGuard {
    private typealias Validate = @convention(c) (
        AnyObject, Selector, NSOutlineView, NSDraggingInfo, AnyObject?, Int
    ) -> NSDragOperation

    enum Result {
        case installed
        /// The data source has no `validateDrop` method. The outline view
        /// must keep its default style.
        case unsupported
        /// The outline view has no data source yet.
        case noDataSource
    }

    /// The classes that have the guard.
    private static var guardedClasses: Set<ObjectIdentifier> = []

    /// Installs the guard on the class of the outline view's data source,
    /// one time for each class.
    static func install(on outline: NSOutlineView) -> Result {
        guard let source = outline.dataSource else { return .noDataSource }
        guard let dataSourceClass = declaredClass(of: source) else { return .unsupported }
        let key = ObjectIdentifier(dataSourceClass)
        if guardedClasses.contains(key) { return .installed }
        let selector = #selector(NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:))
        guard let method = class_getInstanceMethod(dataSourceClass, selector) else { return .unsupported }
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
        return .installed
    }

    /// The class of `object`. When KVO observes the object, the runtime
    /// class is a KVO subclass, and the guard goes on its superclass.
    private static func declaredClass(of object: AnyObject) -> AnyClass? {
        guard let runtimeClass = object_getClass(object) else { return nil }
        if NSStringFromClass(runtimeClass).hasPrefix("NSKVONotifying_") {
            return class_getSuperclass(runtimeClass)
        }
        return runtimeClass
    }
}
