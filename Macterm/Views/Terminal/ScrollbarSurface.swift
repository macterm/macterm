import AppKit
import GhosttyKit

/// A libghostty surface view that `SurfaceScrollView` can host: a pane
/// (`GhosttyTerminalNSView`) or the scroll preview of Settings → Animations
/// (`PreviewSurfaceView`). The preview uses the pane's scroll view, so its
/// scrollbar is the real one.
///
/// The extension holds what is the same for each conformer: the cell
/// height, the text reads, and the wheel path with its mirror of the core's
/// scroll accumulator (`ScrollAccumulator`). The core keeps one accumulator
/// for each surface, so each view keeps its own mirror.
@MainActor
protocol ScrollbarSurface: NSView {
    var surface: ghostty_surface_t? { get }
    /// Mirror of the core's scroll accumulator. Only the extension writes it.
    var scrollAccumulator: ScrollAccumulator { get set }
    /// Set by `SurfaceScrollView`: the scrollback geometry of each
    /// `GHOSTTY_ACTION_SCROLLBAR` (total, offset, len).
    var onScrollbarUpdate: ((UInt64, UInt64, UInt64) -> Void)? { get set }
    /// Set by `SurfaceScrollView`: the pointer shape that libghostty asks for.
    var onMouseShapeChange: ((NSCursor) -> Void)? { get set }
    /// Make the libghostty surface if it does not exist yet and the view can
    /// have one.
    func createSurface()
}

extension ScrollbarSurface {
    /// Cell height in points (not backing pixels). libghostty reports cell
    /// dimensions in backing pixels; divide by the backing scale so callers
    /// working in AppKit's point space (e.g. the scroll view's document view)
    /// get the right value. Returns 0 if the surface isn't ready.
    var cellHeightPoints: CGFloat {
        guard let surface else { return 0 }
        let size = ghostty_surface_size(surface)
        guard size.cell_height_px > 0 else { return 0 }
        let scale = window?.backingScaleFactor ?? 2.0
        return CGFloat(size.cell_height_px) / scale
    }

    var surfaceSize: ghostty_surface_size_s? {
        guard let surface else { return nil }
        return ghostty_surface_size(surface)
    }

    /// Read cell text out of the terminal core via `ghostty_surface_read_text`.
    /// `scrollback == false` returns the visible viewport; `true` returns the
    /// full screen including scrollback. nil when there's no surface or the
    /// core declines the read. This is the same API ghostty's own app uses for
    /// its cached screen/visible contents.
    func readText(scrollback: Bool) -> String? {
        readText(area: scrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT)
    }

    /// Read the cell text of a whole area: `GHOSTTY_POINT_VIEWPORT` (what is
    /// on screen), `GHOSTTY_POINT_ACTIVE` (the bottom screen, wherever the
    /// user has scrolled) or `GHOSTTY_POINT_SCREEN` (with the scrollback).
    func readText(area tag: ghostty_point_tag_e) -> String? {
        guard let surface else { return nil }
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return "" }
        return String(cString: ptr)
    }

    // MARK: - Wheel

    /// Exactly Ghostty.app's `scrollWheel` (SurfaceView_AppKit.swift): the
    /// core does all the scrolling — scrollback, alt-screen cursor keys,
    /// mouse reporting — with the user's `mouse-scroll-multiplier`, so the
    /// feel is Ghostty's. The 2× on precise deltas is Ghostty's own
    /// frontend factor ("subjective, it feels better"), not a Macterm tune.
    func forwardScrollWheel(_ event: NSEvent) {
        forwardScrollWheel(event, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
    }

    /// The wheel path with the deltas of `event` replaced: the part of a pan
    /// of a zoomed picture that the pan could not take (`PaneZoomController`).
    func forwardScrollWheel(_ event: NSEvent, deltaX: CGFloat, deltaY: CGFloat) {
        guard let surface else { return }
        var x = deltaX
        var y = deltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        noteScroll(y: y, precise: event.hasPreciseScrollingDeltas)
        ghostty_surface_mouse_scroll(surface, x, y, GhosttyTerminalNSView.scrollMods(for: event))
    }

    // MARK: - Sub-row scroll offset (smooth scrolling)

    /// Cell height in backing pixels: the units the core accumulates in.
    private var cellHeightPixels: CGFloat {
        guard let surface else { return 0 }
        return CGFloat(ghostty_surface_size(surface).cell_height_px)
    }

    /// Record a delta we are about to hand the core, converted to the pixels
    /// it will add to its accumulator (`Surface.scrollCallback`'s
    /// `yoff_adjusted`). Discrete ticks are normalized to cells first, and on
    /// macOS to at least one, exactly as the core does.
    private func noteScroll(y: CGFloat, precise: Bool) {
        let cell = cellHeightPixels
        guard cell > 0 else { return }
        let multiplier = GhosttyApp.shared.mouseScrollMultiplier
        let pixels: CGFloat = if precise {
            y * CGFloat(multiplier.precision)
        } else {
            (y > 0 ? max(y, 1) : min(y, -1)) * cell * CGFloat(multiplier.discrete)
        }
        scrollAccumulator.advance(pixels: pixels, cellHeight: cell)
    }

    /// Put the viewport `points` below its row-aligned position, which is
    /// what draws a scroller drag between rows.
    ///
    /// libghostty publishes a sub-row viewport offset only from a precision
    /// scroll, and any row-level move (the `scroll_to_row` a drag sends)
    /// clears it — so a drag is row-quantized however smooth the wheel is.
    /// This hands the core a precision delta sized to land its accumulator
    /// on exactly the offset we want (`ScrollAccumulator.nudge`), which
    /// publishes the offset and, being under a cell, commits no row of its
    /// own. Only meaningful with the user's `smooth-scroll` on; without it
    /// the core keeps the remainder as an accumulator detail and draws
    /// nothing differently.
    func applySubRowScrollOffset(pointsBelowRow points: CGFloat) {
        guard let surface else { return }
        let cell = cellHeightPixels
        guard cell > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        // The core's sign: positive is content moved down (scrolled back), so
        // a viewport sitting below its row is a negative remainder.
        let remainder = max(-cell + 1, min(0, -points * scale))
        let multiplier = GhosttyApp.shared.mouseScrollMultiplier.precision
        let delta = scrollAccumulator.nudge(toward: remainder, multiplier: multiplier)
        guard delta != 0 else { return }
        scrollAccumulator.advance(pixels: delta * CGFloat(multiplier), cellHeight: cell)
        // Precision, no momentum: mods bit 0 is `precision` (`scrollMods`).
        ghostty_surface_mouse_scroll(surface, 0, delta, 1)
    }
}
