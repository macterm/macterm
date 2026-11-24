import AppKit
import GhosttyKit
import QuartzCore

/// Drives the zoom of one pane's picture (`PaneZoom`, design/012 section 4).
///
/// - While a pinch moves, the view's layer scales the last frame. The
///   picture is soft. libghostty draws no new frame for each step.
/// - `settleDelay` after the last pinch event, libghostty gets the zoom
///   (`ghostty_surface_set_zoom`). It draws the zoom sharp.
/// - The layer transform maps the zoom of the frame on the layer (`drawn`)
///   to the zoom that the user asked for (`zoom`).
/// - libghostty sets each new frame as the layer's `contents`, on the main
///   thread. A key-value observer runs inside that set and sets the
///   transform again. The frame and its transform therefore change in one
///   Core Animation transaction. When the sharp frame comes, the transform
///   becomes the identity, with no jump.
/// - A pan sends the zoom at once, because a new pan needs no new glyph
///   grid. Only one send waits for its frame at a time.
///
/// The first frame after a send counts as the frame of that zoom. The C API
/// does not say which zoom a frame has. A frame that libghostty drew before
/// the send, and that shows after it, is at the wrong place for one frame.
@MainActor
final class PaneZoomController {
    /// How long after the last pinch event libghostty gets the zoom.
    static let settleDelay: TimeInterval = 0.15
    /// How long to wait for the frame of a send. A covered pane draws no
    /// frame.
    static let frameTimeout: TimeInterval = 1

    private weak var view: GhosttyTerminalNSView?
    /// The zoom that the user asked for.
    private(set) var zoom = PaneZoom.identity
    /// The last zoom that libghostty got.
    private var sent = PaneZoom.identity
    /// The zoom of the frame on the layer.
    private var drawn = PaneZoom.identity
    private var settleTimer: Timer?
    /// Set while a send waits for its frame.
    private var frameTimer: Timer?
    private var contentsObservation: NSKeyValueObservation?
    private weak var observedLayer: CALayer?
    private var contentScale: CGFloat = 0

    init(view: GhosttyTerminalNSView) {
        self.view = view
    }

    var isZoomed: Bool { !zoom.isIdentity }

    /// One pinch event over the pane, at `point` (points, top-left origin).
    func pinch(by magnification: CGFloat, at point: CGPoint) {
        guard let size = paneSize else { return }
        zoom.pinch(by: magnification, at: point, in: size)
        showZoom()
        settleTimer?.invalidate()
        settleTimer = Self.timer(after: Self.settleDelay) { [weak self] in self?.settle() }
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

    /// Back to 1x now: the Reset Zoom command.
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

    /// The pane is about to change its size. libghostty draws the next frame
    /// at the new size, so no transform stays on the layer.
    func viewWillResize() {
        guard isZoomed || drawn != .identity else { return }
        drawn = sent
        setLayerTransform(.identity)
    }

    /// Clamp the pan again for the new size.
    func viewDidResize() {
        guard isZoomed, let size = paneSize else { return }
        let clamped = zoom.clamped(to: size)
        guard clamped != zoom else { return }
        zoom = clamped
        if settleTimer == nil { settle() }
    }

    /// libghostty keeps the zoom in pixels. After a change of the content
    /// scale, it must get the zoom again.
    func contentScaleDidChange(to scale: CGFloat) {
        defer { contentScale = scale }
        guard scale != contentScale, !sent.isIdentity, let surface = view?.surface else { return }
        Self.setZoom(sent, on: surface)
    }

    /// The surface is gone. A new surface starts at 1x.
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

    /// A timer that also fires during a live resize and a menu.
    private static func timer(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func send() {
        // The next frame shows the send that waits. A second send now would
        // make it unknown which send that frame shows.
        guard frameTimer == nil, zoom != sent, let surface = view?.surface else { return }
        Self.setZoom(zoom, on: surface)
        sent = zoom
        observeFrames()
        frameTimer = Self.timer(after: Self.frameTimeout) { [weak self] in self?.frameDidShow() }
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

    /// A new frame is on the layer. It shows the zoom of the last send.
    private func frameDidShow() {
        guard frameTimer != nil else { return }
        frameTimer?.invalidate()
        frameTimer = nil
        drawn = sent
        showZoom()
        // A pan that came while the send waited.
        if settleTimer == nil { send() }
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

    /// Set the transform that shows `zoom` from the frame drawn at `drawn`.
    private func showZoom() {
        guard let view, let size = paneSize else { return }
        guard zoom != drawn else { return setLayerTransform(.identity) }
        let cell = view.surfaceSize.map {
            CGSize(width: CGFloat($0.cell_width_px), height: CGFloat($0.cell_height_px))
        } ?? .zero
        setLayerTransform(PaneZoom.map(
            from: drawn.drawn(cellPixels: cell, in: size),
            to: zoom.drawn(cellPixels: cell, in: size)
        ))
    }

    /// `map` is in points from the top-left of the view. AppKit converts a
    /// view point to the layer's own space (`convertToLayer`), so the code
    /// does not guess which way the layer's y axis goes. The transform
    /// turns about the layer's anchor point.
    private func setLayerTransform(_ map: PaneZoom.Drawn) {
        guard let view, let layer = view.layer else { return }
        let transform: CATransform3D
        if map == .identity {
            transform = CATransform3DIdentity
        } else {
            let height = view.bounds.height
            // A top-left point q is at layer point (ax * q.x + ex, ay * q.y + ey).
            let origin = view.convertToLayer(NSPoint(x: 0, y: height))
            let unit = view.convertToLayer(NSPoint(x: 1, y: height - 1))
            let ax = unit.x - origin.x
            let ay = unit.y - origin.y
            // The map in layer space: x' = scaleX * x + shiftX, and the same for y.
            let shiftX = ax * map.offsetX + origin.x * (1 - map.scaleX)
            let shiftY = ay * map.offsetY + origin.y * (1 - map.scaleY)
            let bounds = layer.bounds
            let anchorX = bounds.minX + layer.anchorPoint.x * bounds.width
            let anchorY = bounds.minY + layer.anchorPoint.y * bounds.height
            transform = CATransform3DMakeAffineTransform(CGAffineTransform(
                a: map.scaleX, b: 0, c: 0, d: map.scaleY,
                tx: shiftX - (1 - map.scaleX) * anchorX,
                ty: shiftY - (1 - map.scaleY) * anchorY
            ))
        }
        // A scaled layer is larger than the pane. The pane's scroll view
        // clips it while the transform is on, so it does not draw over the
        // panes next to it.
        view.enclosingScrollView?.clipsToBounds = map != .identity
        guard !CATransform3DEqualToTransform(layer.transform, transform) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
    }
}
