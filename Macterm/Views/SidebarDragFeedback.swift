import AppKit
import SwiftUI

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
                if found.draggingDestinationFeedbackStyle != .gap {
                    found.draggingDestinationFeedbackStyle = .gap
                }
                outline = found
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
