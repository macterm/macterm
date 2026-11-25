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
/// It also replaces `beginUpdates` of the outline view class. When SwiftUI
/// changes the rows during a drag (a closed project opens under a held
/// drag), AppKit moves the open gap inside the row update and raises
/// "Setting the gap row (index -1) while updating". The guard closes the gap
/// first: it runs the drag update one more time, and validation answers "no
/// drop". The next drag update opens the gap again.
///
/// `SidebarDragFeedbackTests` drives a fake drag on a hosted List. Without
/// the guard, the exit crashes, a project that opens during a drag crashes,
/// and a project drag drops at the wrong slots.
@MainActor
enum OutlineGapDropGuard {
    private typealias Validate = @convention(c) (
        AnyObject, Selector, NSOutlineView, NSDraggingInfo, AnyObject?, Int
    ) -> NSDragOperation
    private typealias Update = @convention(c) (NSOutlineView, Selector) -> Void
    private typealias DragStep = @convention(c) (NSOutlineView, Selector, NSDraggingInfo) -> Void
    private typealias DragCheck = @convention(c) (NSOutlineView, Selector, NSDraggingInfo) -> Bool

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

    /// The key of the drag that is over one outline view, from its last
    /// validation. Nil when no drag is over it.
    private static var dragKey: UInt8 = 0

    /// True while the guard closes a gap before a row update.
    private static var isClosingGap = false

    private static func drag(over outline: NSOutlineView) -> NSDraggingInfo? {
        objc_getAssociatedObject(outline, &dragKey) as? NSDraggingInfo
    }

    private static func setDrag(_ info: NSDraggingInfo?, over outline: NSOutlineView) {
        objc_setAssociatedObject(outline, &dragKey, info, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

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
        guard let dataSourceClass = declaredClass(of: source),
              let outlineClass = declaredClass(of: outline),
              installValidate(on: dataSourceClass),
              installRowUpdates(on: outlineClass)
        else { return .unsupported }
        let names = branchTypes.map(\.rawValue).sorted()
        objc_setAssociatedObject(outline, &branchTypesKey, names, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        return .installed
    }

    /// Replaces `validateDrop` of the data source class. False when the
    /// class has no such method.
    private static func installValidate(on dataSourceClass: AnyClass) -> Bool {
        let key = ObjectIdentifier(dataSourceClass)
        if guardedClasses.contains(key) { return true }
        let selector = #selector(NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:))
        guard let method = class_getInstanceMethod(dataSourceClass, selector) else { return false }
        let original = unsafeBitCast(method_getImplementation(method), to: Validate.self)
        let replacement: @convention(block) (AnyObject, NSOutlineView, NSDraggingInfo, AnyObject?, Int)
            -> NSDragOperation = { source, view, info, item, index in
                MainActor.assumeIsolated {
                    guard view.draggingDestinationFeedbackStyle == .gap else {
                        return original(source, selector, view, info, item, index)
                    }
                    if index < NSOutlineViewDropOnItemIndex {
                        setDrag(nil, over: view)
                        return []
                    }
                    if isClosingGap { return [] }
                    setDrag(info, over: view)
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
        replace(method, of: dataSourceClass, with: replacement)
        guardedClasses.insert(key)
        return true
    }

    /// Replaces `beginUpdates` of the outline view class: a row update in a
    /// drag closes the gap first. The drop and the end of a drag forget the
    /// drag. False when the class lacks one of the methods.
    private static func installRowUpdates(on outlineClass: AnyClass) -> Bool {
        let key = ObjectIdentifier(outlineClass)
        if guardedClasses.contains(key) { return true }
        let begin = #selector(NSOutlineView.beginUpdates)
        let prepare = #selector(NSOutlineView.prepareForDragOperation(_:))
        let conclude = #selector(NSOutlineView.concludeDragOperation(_:))
        guard let beginMethod = class_getInstanceMethod(outlineClass, begin),
              let prepareMethod = class_getInstanceMethod(outlineClass, prepare),
              let concludeMethod = class_getInstanceMethod(outlineClass, conclude)
        else { return false }

        let beginOriginal = unsafeBitCast(method_getImplementation(beginMethod), to: Update.self)
        let beginReplacement: @convention(block) (NSOutlineView) -> Void = { view in
            MainActor.assumeIsolated {
                if !isClosingGap, view.draggingDestinationFeedbackStyle == .gap, let info = drag(over: view) {
                    setDrag(nil, over: view)
                    isClosingGap = true
                    _ = view.draggingUpdated(info)
                    isClosingGap = false
                }
            }
            beginOriginal(view, begin)
        }
        let prepareOriginal = unsafeBitCast(method_getImplementation(prepareMethod), to: DragCheck.self)
        let prepareReplacement: @convention(block) (NSOutlineView, NSDraggingInfo) -> Bool = { view, info in
            MainActor.assumeIsolated { setDrag(nil, over: view) }
            return prepareOriginal(view, prepare, info)
        }
        let concludeOriginal = unsafeBitCast(method_getImplementation(concludeMethod), to: DragStep.self)
        let concludeReplacement: @convention(block) (NSOutlineView, NSDraggingInfo) -> Void = { view, info in
            MainActor.assumeIsolated { setDrag(nil, over: view) }
            concludeOriginal(view, conclude, info)
        }
        replace(beginMethod, of: outlineClass, with: beginReplacement)
        replace(prepareMethod, of: outlineClass, with: prepareReplacement)
        replace(concludeMethod, of: outlineClass, with: concludeReplacement)
        guardedClasses.insert(key)
        return true
    }

    /// Puts `block` in place of `method` on `cls`. A method that the class
    /// only inherits gets its own copy, so that the superclass keeps its
    /// own method.
    private static func replace(_ method: Method, of cls: AnyClass, with block: Any) {
        let implementation = imp_implementationWithBlock(block)
        if !class_addMethod(cls, method_getName(method), implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }

    /// The slot among expandable rows that is nearest to the pointer, for
    /// AppKit's proposal of the child `index` of `item`. `location` is in the
    /// outline view's coordinates. Nil means no drop.
    ///
    /// - On the upper half of the row of `item`: before `item`.
    /// - Among the expandable children of an open `item`: the proposal.
    /// - Else (on the leaf rows of `item`, or below an `item` with no
    ///   expandable children): the nearer of two slots. One is before `item`.
    ///   The other is before its first expandable child, or else after
    ///   `item` and its rows.
    /// - At the top level: the proposal, but never below the slot after the
    ///   last expandable row. SwiftUI refuses a slot that a `ForEach` of leaf
    ///   rows owns, unless that `ForEach` takes the drag.
    /// - A drop on an item (the index -1): no drop. A header takes that drag
    ///   with its own drop view.
    static func branchSlot(in outline: NSOutlineView, item: AnyObject?, index: Int, location: NSPoint) -> Slot? {
        guard index >= 0 else { return nil }
        guard let item else {
            let count = outline.numberOfChildren(ofItem: nil)
            let lastBranch = (0 ..< count).last { outline.isExpandable(outline.child($0, ofItem: nil)) }
            return Slot(item: nil, index: lastBranch.map { min(index, $0 + 1) } ?? index)
        }
        let row = outline.row(forItem: item)
        let position = outline.childIndex(forItem: item)
        guard row >= 0, position >= 0 else { return nil }
        let parent = outline.parent(forItem: item) as AnyObject?
        let header = outline.rect(ofRow: row)
        let before = Slot(item: parent, index: position)
        if location.y < header.midY { return before }
        let count = outline.isItemExpanded(item) ? outline.numberOfChildren(ofItem: item) : 0
        let firstBranch = (0 ..< count).first { outline.isExpandable(outline.child($0, ofItem: item)) }
        let next: Slot
        let nextTop: CGFloat
        if let firstBranch {
            if index >= firstBranch { return Slot(item: item, index: min(index, count)) }
            next = Slot(item: item, index: firstBranch)
            nextTop = outline.rect(ofRow: outline.row(forItem: outline.child(firstBranch, ofItem: item))).minY
        } else {
            next = Slot(item: parent, index: position + 1)
            nextTop = outline.rect(ofRow: lastRow(under: row, in: outline)).maxY
        }
        return location.y - header.minY < nextTop - location.y ? before : next
    }

    /// The last row of the item at `row` and of the rows under it.
    private static func lastRow(under row: Int, in outline: NSOutlineView) -> Int {
        let level = outline.level(forRow: row)
        var last = row
        while last + 1 < outline.numberOfRows, outline.level(forRow: last + 1) > level {
            last += 1
        }
        return last
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
