import AppKit
import GhosttyKit
import SwiftUI

/// A small real libghostty surface that shows fixed text: the previews of
/// Settings → Animations. The renderer draws the animations through fork keys,
/// so only a real surface shows their real look.
///
/// The surface is manual (`manual_io`): no pty, no shell, no session. Macterm
/// feeds the text with `ghostty_surface_feed`. A write of the surface (a
/// terminal reply) goes nowhere. Its userdata is nil, so each action of
/// `GhosttyCallbacks` that needs a view returns early, except the scrollbar
/// action (see below). It is not a
/// `GhosttyTerminalNSView`, so no tab, window, quit prompt or pane list counts
/// it. `GhosttyApp` gives it each config reload (`liveSurfaces`). A toggle
/// therefore applies to it at once. It takes the user's whole config, cursor
/// style and blink included. The surface lives while the view is in a window.
///
/// The scroll preview sits in a pane's own `SurfaceScrollView`, so it has the
/// pane's overlay scrollbar. `GhosttyCallbacks` sends it the scrollbar action
/// through `view(for:)`, because its userdata is nil.
final class PreviewSurfaceView: NSView, ScrollbarSurface {
    enum Kind {
        /// Scrollback to scroll with the wheel or the trackpad. No cursor.
        case scroll
        /// A cursor that a click moves to the clicked cell.
        case cursor
    }

    let kind: Kind
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    /// The cell of the cursor (0-based), which the preview sets itself.
    private var cursorCell = PreviewSurfaceGrid.Cell(column: 0, row: 0)

    @MainActor private static let liveViews = NSHashTable<PreviewSurfaceView>.weakObjects()

    static func allLiveViews() -> [PreviewSurfaceView] {
        liveViews.allObjects
    }

    /// The live preview that owns `surface`, if any.
    static func view(for surface: ghostty_surface_t) -> PreviewSurfaceView? {
        liveViews.allObjects.first { $0.surface == surface }
    }

    // MARK: - ScrollbarSurface

    var scrollAccumulator = ScrollAccumulator()
    var onScrollbarUpdate: ((UInt64, UInt64, UInt64) -> Void)?
    /// Never called: the preview sends no pointer position, so libghostty
    /// computes no pointer shape for it, and the pointer stays an arrow.
    var onMouseShapeChange: ((NSCursor) -> Void)?

    /// The offset of the last scrollbar action, nil before the first.
    private var lastScrollbarOffset: UInt64?

    func surfaceDidUpdateScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        onScrollbarUpdate?(total, offset, len)
        // A pane's overlay scroller is hidden at rest, and the wheel goes to
        // the surface, not to the scroll view. The preview shows the scroller
        // when its rows first arrive and on each move, so that a user sees
        // that it scrolls and where it is.
        guard total > len, offset != lastScrollbarOffset else { return }
        lastScrollbarOffset = offset
        enclosingScrollView?.flashScrollers()
    }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        Self.liveViews.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let surface { ghostty_surface_free(surface) }
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Lifecycle

    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
        windowObservers.removeAll()
        guard let window else {
            destroySurface()
            return
        }
        createSurface()
        let sync: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFocus() }
        }
        let resize: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSize() }
        }
        let occlusion: @Sendable (Notification) -> Void = { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                if let window { WindowOcclusionReports.noteReport(from: window) }
                self?.syncOcclusion()
            }
        }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: sync),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: sync),
            center.addObserver(
                forName: NSWindow.didChangeBackingPropertiesNotification, object: window, queue: .main, using: resize
            ),
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main, using: resize),
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: occlusion
            ),
        ]
        syncOcclusion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if surface == nil { createSurface() } else { updateSize() }
    }

    func createSurface() {
        guard surface == nil, window != nil, let app = GhosttyApp.shared.app else { return }
        let backing = convertToBacking(bounds).size
        guard backing.width > 0, backing.height > 0 else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = nil
        config.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        if SurfaceSizeGate.admits(
            widthPx: UInt32(backing.width), heightPx: UInt32(backing.height),
            cellWidthPx: GhosttyTerminalNSView.lastMeasuredCellSize.width,
            cellHeightPx: GhosttyTerminalNSView.lastMeasuredCellSize.height
        ) {
            config.initial_width_px = UInt32(backing.width)
            config.initial_height_px = UInt32(backing.height)
        }
        Self.enableManualIO(&config)
        guard let surface = ghostty_surface_new(app, &config) else { return }
        self.surface = surface

        syncColorScheme()
        updateSize()
        syncFocus()
        syncOcclusion()
        feedInitialText()
    }

    /// A manual surface with writes that go nowhere. `nonisolated`, because
    /// libghostty calls the callbacks on its IO thread (see
    /// `GhosttyApp.makeRuntimeConfig`).
    nonisolated private static func enableManualIO(_ config: inout ghostty_surface_config_s) {
        config.manual_io = true
        config.manual_write = { _, _, _ in }
        config.manual_resize = { _, _, _, _, _ in }
    }

    private func destroySurface() {
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        // A new surface starts with an empty accumulator.
        scrollAccumulator = ScrollAccumulator()
        lastScrollbarOffset = nil
    }

    private func updateSize() {
        guard let surface, let window else { return }
        let scale = Double(window.backingScaleFactor)
        layer?.contentsScale = CGFloat(scale)
        ghostty_surface_set_content_scale(surface, scale, scale)
        // Gated as every pane resize is (`SurfaceSizeGate`): a sliver would
        // reflow the rows into fragments.
        let backing = convertToBacking(bounds).size
        let cells = ghostty_surface_size(surface)
        guard SurfaceSizeGate.admits(
            widthPx: UInt32(backing.width), heightPx: UInt32(backing.height),
            cellWidthPx: cells.cell_width_px, cellHeightPx: cells.cell_height_px
        )
        else { return }
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
        if let screen = window.screen,
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        {
            ghostty_surface_set_display_id(surface, displayID)
        }
    }

    /// The renderer sleeps while the Settings window is hidden or covered, as
    /// a pane's renderer does (`SurfaceVisibility`).
    private func syncOcclusion() {
        guard let surface else { return }
        let visible = SurfaceVisibility.isVisible(
            rendersForPreview: false,
            hiddenInLayout: false,
            windowIsVisible: window?.isVisible ?? false,
            windowReportsVisible: window?.occlusionState.contains(.visible) ?? false,
            windowHasReportedOcclusion: window.map(WindowOcclusionReports.hasReported) ?? false
        )
        ghostty_surface_set_occlusion(surface, visible)
    }

    /// The cursor animates and blinks only on a focused surface, as in a pane
    /// of a key window.
    private func syncFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, window?.isKeyWindow ?? false)
    }

    func syncColorScheme() {
        guard let surface else { return }
        let isDark = GhosttyApp.shared.windowScheme == .dark
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: - Text

    private func feed(_ text: String) {
        guard let surface else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            ghostty_surface_feed(surface, base, UInt(buffer.count))
        }
    }

    private func feedInitialText() {
        switch kind {
        case .scroll:
            feed(PreviewSurfaceText.scroll())
        case .cursor:
            let text = PreviewSurfaceText.cursor()
            feed(text.bytes)
            cursorCell = text.cursor
        }
    }

    // MARK: - Input

    override var acceptsFirstResponder: Bool {
        false
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard kind == .cursor, let surface else { return }
        let size = ghostty_surface_size(surface)
        // Put the cursor on its known cell first. A wrap or a reflow can have
        // moved it, and the IME point below must name that cell.
        cursorCell.column = min(cursorCell.column, max(Int(size.columns) - 1, 0))
        cursorCell.row = min(cursorCell.row, max(Int(size.rows) - 1, 0))
        feed(PreviewSurfaceText.moveCursor(to: cursorCell))
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = PreviewSurfaceGrid.cell(
            at: CGPoint(x: point.x, y: bounds.height - point.y),
            imePoint: CGPoint(x: x, y: y),
            cursor: cursorCell,
            grid: PreviewSurfaceGrid.Grid(
                cellSize: CGSize(width: Double(size.cell_width_px) / scale, height: Double(size.cell_height_px) / scale),
                columns: Int(size.columns),
                rows: Int(size.rows)
            )
        )
        else { return }
        cursorCell = cell
        feed(PreviewSurfaceText.moveCursor(to: cell))
    }

    override func scrollWheel(with event: NSEvent) {
        guard kind == .scroll, surface != nil else {
            super.scrollWheel(with: event)
            return
        }
        forwardScrollWheel(event)
    }
}

/// The grid math of the cursor preview. Pure, for tests.
enum PreviewSurfaceGrid {
    struct Cell: Equatable {
        var column: Int
        var row: Int
    }

    /// The size of a cell in points, and the grid in cells.
    struct Grid {
        var cellSize: CGSize
        var columns: Int
        var rows: Int
    }

    /// The cell under `point` (points, from the top-left of the view), or nil
    /// outside the grid. The origin of the grid comes from libghostty's IME
    /// point of the cursor at `cursor`: the middle of the cell horizontally
    /// and its bottom edge vertically, padding included
    /// (`Surface.imePointScaled`). So the window padding of the user's config
    /// needs no read of its own.
    static func cell(
        at point: CGPoint,
        imePoint: CGPoint,
        cursor: Cell,
        grid: Grid
    ) -> Cell? {
        let cellSize = grid.cellSize
        guard cellSize.width > 0, cellSize.height > 0, grid.columns > 0, grid.rows > 0 else { return nil }
        let originX = imePoint.x - (Double(cursor.column) + 0.5) * cellSize.width
        let originY = imePoint.y - Double(cursor.row + 1) * cellSize.height
        let column = Int(((point.x - originX) / cellSize.width).rounded(.down))
        let row = Int(((point.y - originY) / cellSize.height).rounded(.down))
        guard (0 ..< grid.columns).contains(column), (0 ..< grid.rows).contains(row) else { return nil }
        return Cell(column: column, row: row)
    }
}

/// The fixed text of the previews, as bytes for the terminal. Pure, for tests.
enum PreviewSurfaceText {
    /// The number of lines of the scroll preview: enough to scroll for a while.
    static let scrollLineCount = 120

    static func scroll() -> String {
        let sentence = String(
            localized: "Scroll here with the wheel or the trackpad.",
            comment: "Text in the scroll preview of Settings → Animations"
        )
        // Hide the cursor: this preview is about the rows.
        var text = "\u{1B}[?25l"
        for line in 1 ... scrollLineCount {
            if line > 1 { text += "\r\n" }
            text += String(format: "%3d  ", line) + sentence
        }
        return text
    }

    /// The text, and the cell of the cursor after it.
    static func cursor() -> (bytes: String, cursor: PreviewSurfaceGrid.Cell) {
        let sentence = String(
            localized: "Click anywhere to move the cursor.",
            comment: "Text in the cursor preview of Settings → Animations"
        )
        let cursor = PreviewSurfaceGrid.Cell(column: 0, row: 1)
        return (sentence + moveCursor(to: cursor), cursor)
    }

    /// CUP to `cell` (1-based in the sequence).
    static func moveCursor(to cell: PreviewSurfaceGrid.Cell) -> String {
        "\u{1B}[\(cell.row + 1);\(cell.column + 1)H"
    }
}

/// The frame of a preview: the background of the user's terminal theme, the
/// rounded corners with a 1 pt edge, and for the scroll preview a pane's
/// `SurfaceScrollView`. The edge (`MactermTheme.nsBorder`) keeps a light
/// theme's preview apart from the Settings group, whose fill is almost the
/// same color.
///
/// A pane draws no default background (`background-default-transparent`):
/// its window paints the theme color (`WindowAppearance`). The Settings
/// window does not, so this view paints `GhosttyApp.backgroundColor`, opaque.
/// It paints again on each `mactermConfigDidChange`, which a config reload, a
/// new theme side and a change of the system appearance all post.
///
/// The pointer that enters the scroll preview shows its scroller.
final class PreviewSurfaceContainer: NSView {
    private static let cornerRadius: CGFloat = 6
    let preview: PreviewSurfaceView
    nonisolated(unsafe) private var configObserver: NSObjectProtocol?
    private var hoverTracking: NSTrackingArea?

    init(kind: PreviewSurfaceView.Kind) {
        preview = PreviewSurfaceView(kind: kind)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        let content: NSView = switch kind {
        case .scroll: SurfaceScrollView(surfaceView: preview)
        case .cursor: preview
        }
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        configObserver = NotificationCenter.default.addObserver(
            forName: .mactermConfigDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.paintTheme() }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        paintTheme()
    }

    private func paintTheme() {
        layer?.backgroundColor = GhosttyApp.shared.backgroundColor.cgColor
        layer?.borderColor = MactermTheme.nsBorder.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        // Only the scroll preview has a scroller to show.
        guard preview.kind == .scroll else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        preview.enclosingScrollView?.flashScrollers()
    }
}

/// The SwiftUI host of a preview.
struct PreviewSurface: NSViewRepresentable {
    let kind: PreviewSurfaceView.Kind

    func makeNSView(context _: Context) -> PreviewSurfaceContainer {
        PreviewSurfaceContainer(kind: kind)
    }

    func updateNSView(_: PreviewSurfaceContainer, context _: Context) {}
}
