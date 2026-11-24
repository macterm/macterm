import CoreGraphics

/// The zoom of a pane's picture (design/012): a view transform that scales
/// the picture inside the pane, as a browser does. The font size, the grid
/// and the pty size do not change. libghostty draws it
/// (`ghostty_surface_set_zoom`, fork patches 0025 and 0026) and applies the
/// inverse where a pointer becomes a cell, so Macterm maps no mouse point.
///
/// A point `p` of the unzoomed picture draws at `scale * p + offset`. All
/// values are in points, from the top-left of the view, as
/// `ghostty_surface_mouse_pos` takes them. The offset is the pan of
/// `ghostty_surface_set_zoom` with its anchor at the origin.
///
/// The zoom is not in the model and is not persisted, as `isReadOnly` is
/// not: a new surface starts at 1x.
struct PaneZoom: Equatable {
    /// The largest scale. libghostty clamps to the same value: a zoomed glyph
    /// atlas doubles in steps, so 4x costs 2.5 to 4 times the memory of 3x
    /// (design/012, E3).
    static let maxScale: CGFloat = 3

    /// 1 is no zoom. The picture never zooms out: outside the grid there is
    /// nothing to draw.
    private(set) var scale: CGFloat = 1
    /// Never positive, and never so negative that the zoomed picture leaves
    /// a gap at the far edge of the pane (`clamped(to:)`).
    private(set) var offset: CGPoint = .zero

    static let identity = PaneZoom()

    var isIdentity: Bool { scale == 1 && offset == .zero }

    /// Scale by a pinch's `magnification` (an `NSEvent.magnification`: 0.1
    /// is 10% larger) about `point`, which stays under the pointer.
    mutating func pinch(by magnification: CGFloat, at point: CGPoint, in size: CGSize) {
        guard magnification.isFinite else { return }
        let next = min(max(scale * (1 + magnification), 1), Self.maxScale)
        let ratio = next / scale
        offset = CGPoint(
            x: point.x - ratio * (point.x - offset.x),
            y: point.y - ratio * (point.y - offset.y)
        )
        scale = next
        self = clamped(to: size)
    }

    /// Move the zoomed picture by `delta` (a two-finger scroll: positive
    /// moves the picture right and down). Returns the part of `delta` that
    /// the pan could not take because the picture is at its edge in that
    /// direction. That part scrolls the terminal.
    mutating func pan(by delta: CGSize, in size: CGSize) -> CGSize {
        let target = CGPoint(x: offset.x + delta.width, y: offset.y + delta.height)
        offset = target
        self = clamped(to: size)
        // What the clamp cut off. Inside the edges this is exactly zero.
        return CGSize(width: target.x - offset.x, height: target.y - offset.y)
    }

    /// The zoom with its offset clamped so that the picture covers the pane
    /// of `size`: `offset <= 0` and `scale * len + offset >= len` on each
    /// axis. libghostty clamps the same way (`renderer.Zoom.resolve`), so
    /// the clamp here only keeps the pan from collecting a move it cannot
    /// draw.
    func clamped(to size: CGSize) -> PaneZoom {
        guard scale > 1, size.width > 0, size.height > 0 else { return .identity }
        var zoom = self
        zoom.offset = CGPoint(
            x: Self.clamp(offset.x, len: size.width, scale: scale),
            y: Self.clamp(offset.y, len: size.height, scale: scale)
        )
        return zoom
    }

    private static func clamp(_ value: CGFloat, len: CGFloat, scale: CGFloat) -> CGFloat {
        min(max(value, len * (1 - scale)), 0)
    }

    // MARK: - As drawn

    /// The zoom as libghostty draws it (`renderer.Zoom.view`). A zoomed cell
    /// is `round(scale x cell)` pixels on each axis. The scale of an axis is
    /// that cell over the base cell. The layer takes the same steps, so the
    /// picture does not move when the sharp frame comes (design/012, E4).
    ///
    /// libghostty also moves the grid by less than one pixel, so that its
    /// first cell is on a whole pixel. The C API does not give the padding.
    /// The sharp frame can therefore land up to one pixel from the layer's
    /// picture.
    struct Drawn: Equatable {
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0

        static let identity = Drawn()
    }

    /// `cellPixels` is the base cell in pixels
    /// (`ghostty_surface_size`); a zero cell draws as the request.
    func drawn(cellPixels: CGSize, in size: CGSize) -> Drawn {
        let zoom = clamped(to: size)
        guard zoom.scale > 1 else { return .identity }
        let scaleX = Self.wholePixelScale(zoom.scale, cell: cellPixels.width)
        let scaleY = Self.wholePixelScale(zoom.scale, cell: cellPixels.height)
        return Drawn(
            scaleX: scaleX,
            scaleY: scaleY,
            offsetX: Self.clamp(zoom.offset.x, len: size.width, scale: scaleX),
            offsetY: Self.clamp(zoom.offset.y, len: size.height, scale: scaleY)
        )
    }

    private static func wholePixelScale(_ scale: CGFloat, cell: CGFloat) -> CGFloat {
        guard cell > 0 else { return scale }
        return (scale * cell).rounded() / cell
    }

    /// The map that takes the picture drawn at `from` to where it draws at
    /// `to`: a point `q` on screen moves to `scale * q + offset` on each
    /// axis. A layer with this transform shows the zoom `to` from a frame
    /// that libghostty drew at `from`.
    static func map(from: Drawn, to: Drawn) -> Drawn {
        let scaleX = to.scaleX / from.scaleX
        let scaleY = to.scaleY / from.scaleY
        return Drawn(
            scaleX: scaleX,
            scaleY: scaleY,
            offsetX: to.offsetX - scaleX * from.offsetX,
            offsetY: to.offsetY - scaleY * from.offsetY
        )
    }
}
