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
/// The style is set only after `OutlineGapDropGuard` is in place. Without
/// the guard, a drag that leaves the outline view crashes SwiftUI.
/// `isGuarded` is true while the guard is in place. The List adds the drop
/// slots of projects only then: the guard moves a project proposal to a slot
/// that a project `ForEach` owns, so the gap opens where the project lands.
///
/// A folder from Finder shows no gap, because `SidebarFolderDropTarget` takes
/// that drag above the outline view.
struct SidebarDragFeedback: NSViewRepresentable {
    /// The pasteboard types that only the rows of projects take.
    var branchTypes: Set<NSPasteboard.PasteboardType> = []
    @Binding var isGuarded: Bool

    func makeNSView(context _: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ view: ProbeView, context _: Context) {
        view.branchTypes = branchTypes
        let report: (Bool) -> Void = { guarded in
            if isGuarded != guarded { isGuarded = guarded }
        }
        view.onGuardChange = report
        // A new binding (a new sidebar state) gets the state of the probe.
        // Not during this update: SwiftUI does not allow a state change here.
        if view.isGuarded != isGuarded {
            let guarded = view.isGuarded
            DispatchQueue.main.async { report(guarded) }
        }
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
        var branchTypes: Set<NSPasteboard.PasteboardType> = []
        var onGuardChange: (Bool) -> Void = { _ in }
        /// True while the guard is on the outline view of this probe.
        var isGuarded: Bool {
            gapIsAllowed && outline?.window != nil
        }

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
                switch OutlineGapDropGuard.install(on: found, branchTypes: branchTypes) {
                case .installed:
                    outline = found
                    gapIsAllowed = true
                    if found.draggingDestinationFeedbackStyle != .gap {
                        found.draggingDestinationFeedbackStyle = .gap
                    }
                    onGuardChange(true)
                    return
                case .unsupported:
                    // Fail closed: the insertion line stays, and no later
                    // pass tries again.
                    outline = found
                    gapIsAllowed = false
                    onGuardChange(false)
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

/// Gives SwiftUI only the drop proposals that it can take, on an outline
/// view in the gap style. Never set `.gap` on a SwiftUI outline view without
/// it.
///
/// It replaces the `validateDrop` method of the data source class. Calls
/// for an outline view in another style go to SwiftUI with no change. Other
/// Lists keep the default style, so the guard does not touch their drags. On
/// an outline view in the gap style, the guard does two things:
///
/// 1. **The exit.** `NSOutlineView.draggingExited` validates one more drop
///    to close the gap. That call has no item and the child index -2.
///    SwiftUI's data source reads its rows at that index, and the app crashes
///    with "index -2 out of bounds". A drag leaves the outline view each time
///    that it goes onto a row with its own `.dropDestination`, for example a
///    project header. The guard answers "no drop" and does not call SwiftUI.
/// 2. **A branch drag** (a pasteboard type of `branchTypes(of:)`: a project).
///    Only the `ForEach`s of expandable rows take it. AppKit proposes the
///    slots between the leaf rows (the tabs), and SwiftUI refuses them. Then
///    the gap stays at the slot where the drag started. The guard moves each
///    proposal to the nearest slot among expandable rows (`branchSlot`) and
///    gives that slot to AppKit. The gap and the drop are then at the same
///    slot. The guard never proposes a slot in an item with no children or in
///    a closed item, because SwiftUI crashes on those.
///
/// `SidebarDragFeedbackTests` drives a fake drag on a hosted List. Without
/// the guard, the exit crashes, and a project drag drops at the wrong slots.
@MainActor
enum OutlineGapDropGuard {
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

    /// A drop slot: the child `index` of `item` (nil: the top level).
    struct Slot {
        let item: AnyObject?
        let index: Int
    }

    /// The classes that have the guard.
    private static var guardedClasses: Set<ObjectIdentifier> = []

    /// The key of the branch types of one outline view.
    private static var branchTypesKey: UInt8 = 0

    /// The pasteboard types that only the `ForEach`s of expandable rows of
    /// `outline` take. Each outline view has its own: the guard is on a
    /// class, which other Lists share.
    static func branchTypes(of outline: NSOutlineView) -> [NSPasteboard.PasteboardType] {
        (objc_getAssociatedObject(outline, &branchTypesKey) as? [String] ?? []).map { .init($0) }
    }

    /// Installs the guard on the class of the outline view's data source,
    /// one time for each class, and sets the branch types of `outline`.
    static func install(
        on outline: NSOutlineView,
        branchTypes: Set<NSPasteboard.PasteboardType> = []
    ) -> Result {
        guard let source = outline.dataSource else { return .noDataSource }
        guard let dataSourceClass = declaredClass(of: source) else { return .unsupported }
        let names = branchTypes.map(\.rawValue).sorted()
        objc_setAssociatedObject(outline, &branchTypesKey, names, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        let key = ObjectIdentifier(dataSourceClass)
        if guardedClasses.contains(key) { return .installed }
        let selector = #selector(NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:))
        guard let method = class_getInstanceMethod(dataSourceClass, selector) else { return .unsupported }
        let original = unsafeBitCast(method_getImplementation(method), to: Validate.self)
        let replacement: @convention(block) (AnyObject, NSOutlineView, NSDraggingInfo, AnyObject?, Int)
            -> NSDragOperation = { source, view, info, item, index in
                MainActor.assumeIsolated {
                    guard view.draggingDestinationFeedbackStyle == .gap else {
                        return original(source, selector, view, info, item, index)
                    }
                    if index < NSOutlineViewDropOnItemIndex { return [] }
                    let types = OutlineGapDropGuard.branchTypes(of: view)
                    guard !types.isEmpty, info.draggingPasteboard.availableType(from: types) != nil else {
                        return original(source, selector, view, info, item, index)
                    }
                    let location = view.convert(info.draggingLocation, from: nil)
                    guard let slot = branchSlot(in: view, item: item, index: index, location: location) else {
                        return []
                    }
                    view.setDropItem(slot.item, dropChildIndex: slot.index)
                    return original(source, selector, view, info, slot.item, slot.index)
                }
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

    /// The slot among expandable rows that is nearest to AppKit's proposal
    /// of the child `index` of `item`. `location` is in the outline view's
    /// coordinates. Nil means no drop.
    ///
    /// - On the upper half of the row of `item`: before `item`.
    /// - In an open `item` with expandable children: among them, at the
    ///   first one or later (a proposal among the leaf rows moves down to
    ///   the first expandable child).
    /// - Else: after `item`.
    /// - At the top level: the proposal with no change. SwiftUI refuses it
    ///   when a `ForEach` of leaf rows owns that slot.
    /// - A drop on an item (the index -1): no drop. A header takes that drag
    ///   with its own drop view.
    static func branchSlot(in outline: NSOutlineView, item: AnyObject?, index: Int, location: NSPoint) -> Slot? {
        guard index >= 0 else { return nil }
        guard let item else { return Slot(item: nil, index: index) }
        let row = outline.row(forItem: item)
        let position = outline.childIndex(forItem: item)
        guard row >= 0, position >= 0 else { return nil }
        let parent = outline.parent(forItem: item) as AnyObject?
        if location.y < outline.rect(ofRow: row).midY {
            return Slot(item: parent, index: position)
        }
        let count = outline.numberOfChildren(ofItem: item)
        if outline.isItemExpanded(item), count > 0,
           let firstBranch = (0 ..< count).first(where: { outline.isExpandable(outline.child($0, ofItem: item)) })
        {
            return Slot(item: item, index: min(max(index, firstBranch), count))
        }
        return Slot(item: parent, index: position + 1)
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
