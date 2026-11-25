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
    /// The drags that only the rows of projects take, and where those rows
    /// are at the top level.
    var branches = OutlineGapDropGuard.Branches()
    @Binding var isGuarded: Bool
    /// Gets the drag whose gap is open on the rows, and nil when the gap
    /// closes (`OutlineGapDropGuard.observeOpenDrag`).
    var onOpenDrag: (NSDraggingInfo?) -> Void = { _ in }

    func makeNSView(context _: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ view: ProbeView, context _: Context) {
        view.branches = branches
        view.onOpenDrag = onOpenDrag
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
        var branches = OutlineGapDropGuard.Branches()
        var onGuardChange: (Bool) -> Void = { _ in }
        var onOpenDrag: (NSDraggingInfo?) -> Void = { _ in }
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
                // Cheap: SwiftUI can set the style back, and the rows change.
                if gapIsAllowed {
                    OutlineGapDropGuard.configure(outline, branches: branches)
                    if outline.draggingDestinationFeedbackStyle != .gap {
                        outline.draggingDestinationFeedbackStyle = .gap
                    }
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
                switch OutlineGapDropGuard.install(on: found, branches: branches) {
                case .installed:
                    outline = found
                    OutlineGapDropGuard.observeOpenDrag(on: found) { [weak self] info in self?.onOpenDrag(info) }
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
/// It replaces methods of the data source class and of the outline view
/// class, which other Lists share. Each replacement checks the style first:
/// for an outline view in another style, it calls the original with no
/// change. On an outline view in the gap style, the guard does three things:
///
/// 1. **The exit.** `NSOutlineView.draggingExited` validates one more drop
///    to close the gap. That call has no item and the child index -2.
///    SwiftUI's data source reads its rows at that index, and the app crashes
///    with "index -2 out of bounds". A drag leaves the outline view each time
///    that it goes onto a row with its own `.dropDestination`, for example a
///    project header. The guard answers "no drop" and does not call SwiftUI.
/// 2. **A branch drag** (a pasteboard type of `branches(of:).types`: a project).
///    Only the `ForEach`s of expandable rows take it. AppKit proposes the
///    slots between the leaf rows (the tabs), and SwiftUI refuses them. Then
///    the gap stays at the slot where the drag started. The guard moves each
///    proposal to the nearest slot among expandable rows (`branchSlot`) and
///    gives that slot to AppKit. The gap and the drop are then at the same
///    slot. The guard never proposes a slot in an item with no children or in
///    a closed item, because SwiftUI crashes on those.
///
/// 3. **A row update during a drag.** When SwiftUI changes the rows while the
///    gap is open (a closed project opens under a held drag), AppKit moves
///    the gap inside the row update. It then raises "Setting the gap row
///    (index -1) while updating", and the app stops. The guard replaces
///    `beginUpdates` and closes the gap before the update: it sends the drag
///    an exit, which always closes the gap. (A repeated drag update does not:
///    AppKit skips validation when the pointer did not move.) On the next
///    turn of the run loop, after the update, it sends the drag an entry
///    again, so the gap opens at the new slot. To do this, the guard keeps a
///    weak reference to the drag while the gap is open. It forgets the drag
///    when validation answers "no drop", when the drag exits, and at the
///    drop (`prepareForDragOperation:` and `concludeDragOperation:`).
///
/// `SidebarDragFeedbackTests` drives a fake drag on a hosted List. Without
/// the guard, the exit crashes, a project that opens during a drag crashes,
/// and a project drag drops at the wrong slots. A crash stops the whole test
/// process, not only one test.
@MainActor
enum OutlineGapDropGuard {
    private typealias Validate = @convention(c) (
        AnyObject, Selector, NSOutlineView, NSDraggingInfo, AnyObject?, Int
    ) -> NSDragOperation
    private typealias BeginUpdates = @convention(c) (NSOutlineView, Selector) -> Void
    private typealias ConcludeDrag = @convention(c) (NSOutlineView, Selector, NSDraggingInfo) -> Void
    private typealias PrepareDrag = @convention(c) (NSOutlineView, Selector, NSDraggingInfo) -> Bool

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

    /// The drags that only the `ForEach`s of expandable rows take, and the
    /// top-level rows that take them.
    struct Branches {
        /// The pasteboard types of a branch drag.
        var types: Set<NSPasteboard.PasteboardType> = []
        /// The number of top-level rows that take a branch drag (the
        /// projects).
        var topLevelCount = 0
        /// The number of top-level rows after them (the scratch rows).
        var trailingCount = 0
    }

    /// `Branches` as an object, because an associated object must be one.
    private final class BranchesBox {
        let value: Branches
        init(_ value: Branches) {
            self.value = value
        }
    }

    /// The key of the branches of one outline view.
    private static var branchesKey: UInt8 = 0

    /// The key of the drag whose gap is open on one outline view.
    private static var dragKey: UInt8 = 0

    /// A weak reference: the guard never keeps a drag that AppKit ended.
    private final class DragReference {
        weak var info: NSDraggingInfo?
        init(_ info: NSDraggingInfo) {
            self.info = info
        }
    }

    /// The drag whose gap is open on `outline`, or nil.
    private static func openDrag(on outline: NSOutlineView) -> NSDraggingInfo? {
        (objc_getAssociatedObject(outline, &dragKey) as? DragReference)?.info
    }

    private static func setOpenDrag(_ info: NSDraggingInfo?, on outline: NSOutlineView) {
        objc_setAssociatedObject(outline, &dragKey, info.map(DragReference.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if !isClosingForUpdate { observer(of: outline)?(info) }
    }

    /// True while the guard closes a gap before a row update (point 3). The
    /// gap opens again after the update, so the observer sees no close.
    private static var isClosingForUpdate = false

    /// The key of the observer of one outline view.
    private static var observerKey: UInt8 = 0

    /// An observer as an object, because an associated object must be one.
    private final class ObserverBox {
        let body: (NSDraggingInfo?) -> Void
        init(_ body: @escaping (NSDraggingInfo?) -> Void) {
            self.body = body
        }
    }

    private static func observer(of outline: NSOutlineView) -> ((NSDraggingInfo?) -> Void)? {
        (objc_getAssociatedObject(outline, &observerKey) as? ObserverBox)?.body
    }

    /// Tells `body` the drag of each validation that opens the gap on
    /// `outline`, and nil when the gap closes: at an exit, at a refused
    /// proposal and at the drop. It is called at each drag update. The
    /// sidebar opens its pin band with it while a tab drag is on the rows.
    static func observeOpenDrag(on outline: NSOutlineView, _ body: @escaping (NSDraggingInfo?) -> Void) {
        objc_setAssociatedObject(outline, &observerKey, ObserverBox(body), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The branches of `outline`. Each outline view has its own: the guard
    /// is on a class, which other Lists share.
    static func branches(of outline: NSOutlineView) -> Branches {
        (objc_getAssociatedObject(outline, &branchesKey) as? BranchesBox)?.value ?? Branches()
    }

    /// Sets the branches of `outline`. The sidebar sets them again at each
    /// update, because the number of projects changes.
    static func configure(_ outline: NSOutlineView, branches: Branches) {
        objc_setAssociatedObject(outline, &branchesKey, BranchesBox(branches), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Installs the guard on the class of the outline view's data source,
    /// one time for each class, and sets the branches of `outline`.
    static func install(
        on outline: NSOutlineView,
        branches: Branches = Branches()
    ) -> Result {
        guard let source = outline.dataSource else { return .noDataSource }
        guard let dataSourceClass = declaredClass(of: source),
              let outlineClass = declaredClass(of: outline),
              installValidate(on: dataSourceClass),
              installGapClose(on: outlineClass)
        else { return .unsupported }
        configure(outline, branches: branches)
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
                        setOpenDrag(nil, on: view)
                        return []
                    }
                    let operation: NSDragOperation
                    let branches = OutlineGapDropGuard.branches(of: view)
                    if !branches.types.isEmpty,
                       info.draggingPasteboard.availableType(from: Array(branches.types)) != nil
                    {
                        let location = view.convert(info.draggingLocation, from: nil)
                        if let topLevel = topLevelSlots(of: view, branches: branches),
                           let slot = branchSlot(
                               in: view,
                               item: item,
                               index: index,
                               location: location,
                               topLevel: topLevel
                           )
                        {
                            view.setDropItem(slot.item, dropChildIndex: slot.index)
                            operation = original(source, selector, view, info, slot.item, slot.index)
                        } else {
                            operation = []
                        }
                    } else {
                        operation = original(source, selector, view, info, item, index)
                    }
                    setOpenDrag(operation.isEmpty ? nil : info, on: view)
                    return operation
                }
            }
        replace(method, of: dataSourceClass, with: replacement)
        guardedClasses.insert(key)
        return true
    }

    /// Replaces `beginUpdates` of the outline view class: a row update
    /// while a gap is open closes the gap first. Also replaces the two drop
    /// steps, which forget the drag. False when the class lacks one of the
    /// methods.
    private static func installGapClose(on outlineClass: AnyClass) -> Bool {
        let key = ObjectIdentifier(outlineClass)
        if guardedClasses.contains(key) { return true }
        let begin = #selector(NSOutlineView.beginUpdates)
        let prepare = #selector(NSOutlineView.prepareForDragOperation(_:))
        let conclude = #selector(NSOutlineView.concludeDragOperation(_:))
        guard let beginMethod = class_getInstanceMethod(outlineClass, begin),
              let prepareMethod = class_getInstanceMethod(outlineClass, prepare),
              let concludeMethod = class_getInstanceMethod(outlineClass, conclude)
        else { return false }

        let beginOriginal = unsafeBitCast(method_getImplementation(beginMethod), to: BeginUpdates.self)
        let beginReplacement: @convention(block) (NSOutlineView) -> Void = { view in
            MainActor.assumeIsolated {
                guard view.draggingDestinationFeedbackStyle == .gap, let info = openDrag(on: view) else { return }
                isClosingForUpdate = true
                view.draggingExited(info)
                isClosingForUpdate = false
                reenter(DragReference(info), on: view)
            }
            beginOriginal(view, begin)
        }
        let prepareOriginal = unsafeBitCast(method_getImplementation(prepareMethod), to: PrepareDrag.self)
        let prepareReplacement: @convention(block) (NSOutlineView, NSDraggingInfo) -> Bool = { view, info in
            MainActor.assumeIsolated { setOpenDrag(nil, on: view) }
            return prepareOriginal(view, prepare, info)
        }
        let concludeOriginal = unsafeBitCast(method_getImplementation(concludeMethod), to: ConcludeDrag.self)
        let concludeReplacement: @convention(block) (NSOutlineView, NSDraggingInfo) -> Void = { view, info in
            MainActor.assumeIsolated { setOpenDrag(nil, on: view) }
            concludeOriginal(view, conclude, info)
        }
        replace(beginMethod, of: outlineClass, with: beginReplacement)
        replace(prepareMethod, of: outlineClass, with: prepareReplacement)
        replace(concludeMethod, of: outlineClass, with: concludeReplacement)
        guardedClasses.insert(key)
        return true
    }

    /// After a row update closed the gap: enter the drag again on the next
    /// turn of the run loop, outside SwiftUI's update, so that the gap opens
    /// at the new slot with no pointer move. Only while the drag is alive,
    /// no newer validation opened a gap, and the pointer is over `outline`.
    private static func reenter(_ drag: DragReference, on outline: NSOutlineView) {
        DispatchQueue.main.async { [weak outline] in
            MainActor.assumeIsolated {
                guard let outline, openDrag(on: outline) == nil else { return }
                guard let info = drag.info,
                      outline.window === info.draggingDestinationWindow,
                      dropView(at: info.draggingLocation, in: outline) === outline
                else {
                    // The gap stays closed: now the observer sees the close.
                    observer(of: outline)?(nil)
                    return
                }
                _ = outline.draggingEntered(info)
            }
        }
    }

    /// The deepest view in `outline` (with `outline` itself) that is under
    /// `point` (window coordinates) and takes drags. A row with its own drop
    /// destination (a project header) takes the drag from the outline view.
    private static func dropView(at point: NSPoint, in outline: NSOutlineView) -> NSView? {
        deepestDropView(in: outline) { $0.convert($0.bounds, to: nil).contains(point) }
    }

    /// The deepest visible view in `view` (with `view` itself) that takes
    /// drags, among the views for which `includes` is true.
    private static func deepestDropView(in view: NSView, where includes: (NSView) -> Bool) -> NSView? {
        guard !view.isHidden, includes(view) else { return nil }
        for subview in view.subviews.reversed() {
            if let found = deepestDropView(in: subview, where: includes) { return found }
        }
        return view.registeredDraggedTypes.isEmpty ? nil : view
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

    /// The top-level slots that a branch drag can take: from the slot
    /// before the first project to the slot after the last one. Nil (no
    /// drop) when the counts of `branches` do not fit the rows of the
    /// outline view, for example for a moment after a change of the rows.
    static func topLevelSlots(of outline: NSOutlineView, branches: Branches) -> ClosedRange<Int>? {
        let count = branches.topLevelCount
        let first = outline.numberOfChildren(ofItem: nil) - branches.trailingCount - count
        return first >= 0 && count > 0 ? first ... first + count : nil
    }

    /// The slot among expandable rows that is nearest to the pointer, for
    /// AppKit's proposal of the child `index` of `item`. `location` is in the
    /// outline view's coordinates. `topLevel` is the range of `topLevelSlots`.
    /// Nil means no drop.
    ///
    /// - In a top-level row outside `topLevel` (a pinned row): no drop.
    /// - On the upper half of the row of `item`: before `item`.
    /// - Among the expandable children of an open `item`: the proposal.
    /// - Else (on the leaf rows of `item`, or below an `item` with no
    ///   expandable children): the nearer of two slots. One is before `item`.
    ///   The other is before its first expandable child, or else after
    ///   `item` and its rows. The slot before `item` moves the row of `item`
    ///   down by one row. When the drop view of that row (a header with its
    ///   own drop destination) then comes under the pointer, it takes the
    ///   drag and the gap closes. So in that case the guard uses the other
    ///   slot. The gap is as tall as the dragged row, and a project drag
    ///   drags a header row, so the shift is the height of the header row.
    ///   Only the height counts: the drop view of a header has the full
    ///   width of the row.
    /// - At the top level: the proposal, limited to `topLevel`.
    /// - A drop on an item (the index -1): no drop. A header takes that drag
    ///   with its own drop view.
    static func branchSlot(
        in outline: NSOutlineView,
        item: AnyObject?,
        index: Int,
        location: NSPoint,
        topLevel: ClosedRange<Int>
    ) -> Slot? {
        guard index >= 0 else { return nil }
        guard let item else {
            guard index >= topLevel.lowerBound else { return nil }
            // The slot before the first project, only from its row or below:
            // never from the rows above it (the pinned rows).
            if index == topLevel.lowerBound {
                let firstRow = outline.row(forItem: outline.child(index, ofItem: nil))
                guard firstRow >= 0, location.y >= outline.rect(ofRow: firstRow).minY else { return nil }
            }
            return Slot(item: nil, index: min(index, topLevel.upperBound))
        }
        var top: AnyObject = item
        while let parent = outline.parent(forItem: top) as AnyObject? {
            top = parent
        }
        guard (topLevel.lowerBound ..< topLevel.upperBound).contains(outline.childIndex(forItem: top)) else {
            return nil
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
        guard location.y - header.minY < nextTop - location.y else { return next }
        if let band = dropBand(ofRow: row, in: outline) {
            let shifted = band.offsetBy(dx: 0, dy: header.height)
            if location.y >= shifted.minY, location.y < shifted.maxY { return next }
        }
        return before
    }

    /// The vertical band of the row `row` that a drop view of the row (a
    /// header with its own drop destination) covers, at the place of the
    /// row with no gap. Nil when the row has no drop view, or has no row
    /// view: the row is then off screen, and the pointer is not near it.
    private static func dropBand(ofRow row: Int, in outline: NSOutlineView) -> NSRect? {
        guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false),
              let dropView = deepestDropView(in: rowView, where: { _ in true })
        else { return nil }
        let frame = dropView.convert(dropView.bounds, to: outline)
        let offset = outline.rect(ofRow: row).minY - rowView.frame.minY
        return frame.offsetBy(dx: 0, dy: offset)
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
