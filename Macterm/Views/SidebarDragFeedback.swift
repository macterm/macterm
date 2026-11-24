import AppKit
import SwiftUI

/// Sets the drop feedback of the sidebar's outline view to `.gap`: during a
/// drag, the rows below the drop slot move apart and leave an empty slot, as
/// in the Finder sidebar. The default of a `.sidebar` List is `.sourceList`,
/// which draws an insertion line.
///
/// SwiftUI has no modifier for the style, so this view, a `.background` of
/// the List, finds the outline view that SwiftUI made beside it and sets the
/// style on it. SwiftUI does not reset the style when rows change, collapse
/// or expand (measured on macOS 27), but it can make a new outline view, so
/// each update of the sidebar sets it again. The drops do not change: the
/// same `.dropDestination`s get the same offsets, and AppKit moves the rows
/// (and respects Reduce Motion).
///
/// A folder from Finder shows no gap: `SidebarFolderDropTarget` takes that
/// drag above the outline view, and the project goes to the end of the list.
struct SidebarDragFeedback: NSViewRepresentable {
    func makeNSView(context _: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ view: ProbeView, context _: Context) {
        view.applySoon()
    }

    final class ProbeView: NSView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applySoon()
        }

        /// Deferred one turn, so that SwiftUI has put the outline view in
        /// the window before the search.
        func applySoon() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        /// The nearest ancestor that holds an outline view holds this List's,
        /// because the probe is a sibling of the List's scroll view.
        private func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let outline = view.firstDescendant(ofType: NSOutlineView.self) {
                    if outline.draggingDestinationFeedbackStyle != .gap {
                        outline.draggingDestinationFeedbackStyle = .gap
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
