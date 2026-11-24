import AppKit
import GhosttyKit
import QuartzCore

/// Drives the zoom of one pane's picture (`PaneZoom`, design/012 section 4).
///
/// - While a pinch moves, the layer of the view scales the last frame (soft
///   at a high zoom). libghostty does not draw a new zoom for each step.
/// - `settleDelay` after the last pinch event, libghostty gets the zoom
///   (`ghostty_surface_set_zoom`) and draws it sharp.
/// - The layer transform always maps the zoom of the frame that the layer
///   shows (`drawn`) to the zoom that the user asked for (`zoom`). It is set
///   again at each new frame, in the same Core Animation transaction as the
///   frame's `contents`: libghostty sets them on the main thread, and the
///   key-value observer runs inside that set. When the sharp frame comes,
///   the transform becomes the identity with no jump.
/// - A pan sends the zoom at once: a new scale needs a new glyph grid, a new
///   pan does not.
///
/// The frame that comes first after a send counts as the frame of that
/// zoom. A frame that libghostty drew before the send and shows after it
/// is therefore drawn for one frame at the wrong place. The C API does not
/// say which zoom a frame has.
@MainActor
final class PaneZoomController {
    /// How long after the last pinch event libghostty gets the zoom.
    static let settleDelay: TimeInterval = 0.15
    /// How long to wait for a frame after a send before the layer counts it
    /// as drawn (a covered pane draws no frame).
    static let frameTimeout: TimeInterval = 1

    private weak var view: GhosttyTerminalNSView?
    /// The zoom that the user asked for.
    private(set) var zoom = PaneZoom.identity
    /// The last zoom that libghostty got.
    private var sent = PaneZoom.identity
    /// The zoom of the frame that the layer shows.
    private var drawn = PaneZoom.identity
    private var settleTimer: Timer?
    private var frameTimer: Timer?
    private var contentsObservation: NSKeyValueObservation?
    private weak var observedLayer: CALayer?

    init(view: GhosttyTerminalNSView) {
        self.view = view
    }

    var isZoomed: Bool { !zoom.isIdentity }

    /// One pinch event over the pane, at `point` (points, top-left origin).
    func pinch(by magnification: CGFloat, at point: CGPoint) {
        guard let size = paneSize else { return }
        zoom.pinch(by: magnification, at: point, in: size)
        showZoom()
        scheduleSettle()
    }

    /// A two-finger scroll while zoomed. Returns what the pan could not take,
    /// which scrolls the terminal.
    func pan(by delta: CGSize) -> CGSize {
        guard isZoomed, let size = paneSize else { return delta }
        let leftover = zoom.pan(by: delta, in: size)
        guard zoom != sent else { return leftover }
        showZoom()
        // A pinch that has not settled sends the pan with its scale.
        if settleTimer == nil { send() }
        return leftover
    }

    /// Back to 1x at once: the Reset Zoom command.
    func reset() {
        zoom = .identity
        settle()
    }

    /// Send the zoom now, not after the settle delay.
    func settle() {
        settleTimer?.invalidate()
        settleTimer = nil
        showZoom()
        send()
    }

    /// The pane is about to change its size. libghostty draws a resized frame
    /// at the new size, so no transform may stay on the layer, and the pan
    /// is clamped again for the new size.
    func viewWillResize() {
        guard !zoom.isIdentity || !drawn.isIdentity else { return }
        drawn = sent
        setLayerTransform(.identity)
    }

    func viewDidResize() {
        guard let size = paneSize, !zoom.isIdentity else { return }
        let clamped = zoom.clamped(to: size)
        guard clamped != zoom else { return }
        zoom = clamped
        if settleTimer == nil { settle() }
    }

    /// libghostty keeps the zoom in pixels. After a change of the content
    /// scale it must get the zoom again.
    func contentScaleDidChange() {
        guard !sent.isIdentity, let surface = view?.surface else { return }
        Self.setZoom(sent, on: surface)
    }

    /// The surface is gone: a new surface starts at 1x.
    func surfaceDidEnd() {
        settleTimer?.invalidate()
        settleTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        contentsObservation = nil
        observedLayer = nil
        zoom = .identity
        sent = .identity
        drawn = .identity
        setLayerTransform(.identity)
    }

    // MARK: - Private

    private var paneSize: CGSize? {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        return view.bounds.size
    }

    private func scheduleSettle() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle() }
        }
    }

    private func send() {
        guard zoom != sent, let surface = view?.surface else { return }
        Self.setZoom(zoom, on: surface)
        sent = zoom
        observeFrames()
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: Self.frameTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.frameDidShow() }
        }
    }

    private static func setZoom(_ zoom: PaneZoom, on surface: ghostty_surface_t) {
        ghostty_surface_set_zoom(
            surface,
            Double(zoom.scale),
            0,
            0,
            Double(zoom.offset.x),
            Double(zoom.offset.y)
        )
    }

    /// A new frame is on the layer: it shows the zoom that libghostty got.
    private func frameDidShow() {
        frameTimer?.invalidate()
        frameTimer = nil
        guard drawn != sent else { return }
        drawn = sent
        showZoom()
    }

    private func observeFrames() {
        guard let layer = view?.layer, layer !== observedLayer else { return }
        observedLayer = layer
        contentsObservation = layer.observe(\.contents, options: []) { [weak self] _, _ in
            // libghostty sets the contents on the main thread
            // (IOSurfaceLayer.setSurface).
            MainActor.assumeIsolated { self?.frameDidShow() }
        }
    }

    /// Put the transform that shows `zoom` from the frame drawn at `drawn`.
    private func showZoom() {
        guard let view, let size = paneSize else { return }
        if zoom == drawn {
            setLayerTransform(.identity)
            return
        }
        let cell = view.surfaceSize.map {
            CGSize(width: CGFloat($0.cell_width_px), height: CGFloat($0.cell_height_px))
        } ?? .zero
        let map = PaneZoom.map(
            from: drawn.drawn(cellPixels: cell, in: size),
            to: zoom.drawn(cellPixels: cell, in: size)
        )
        setLayerTransform(map)
    }

    /// `map` is in points from the top-left of the view. The layer's own
    /// space can have its y axis up, and its transform turns about its
    /// anchor point.
    private func setLayerTransform(_ map: PaneZoom.Drawn) {
        guard let layer = view?.layer else { return }
        let transform: CATransform3D
        if map == .identity {
            transform = CATransform3DIdentity
        } else {
            let bounds = layer.bounds
            let anchorX = bounds.minX + layer.anchorPoint.x * bounds.width
            let anchorY = bounds.minY + layer.anchorPoint.y * bounds.height
            // The map in layer space: x' = scaleX * x + shiftX, and the same
            // for y, with y measured from the top when the layer is flipped
            // and from the bottom when it is not.
            let shiftX = map.offsetX + bounds.minX * (1 - map.scaleX)
            let shiftY = layer.contentsAreFlipped()
                ? map.offsetY + bounds.minY * (1 - map.scaleY)
                : bounds.height * (1 - map.scaleY) - map.offsetY + bounds.minY * (1 - map.scaleY)
            transform = CATransform3DMakeAffineTransform(CGAffineTransform(
                a: map.scaleX, b: 0, c: 0, d: map.scaleY,
                tx: shiftX - (1 - map.scaleX) * anchorX,
                ty: shiftY - (1 - map.scaleY) * anchorY
            ))
        }
        guard !CATransform3DEqualToTransform(layer.transform, transform) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
    }
}
