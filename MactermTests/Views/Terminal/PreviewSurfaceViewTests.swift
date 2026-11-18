import AppKit
@testable import Macterm
import Testing

/// The Settings → Animations previews: the cell under a click, the fixed
/// text, and the frame that each preview sits in.
@MainActor
struct PreviewSurfaceViewTests {
    /// Cells of 8 × 16 pt, with the padding of 2 pt on the left and 4 pt on
    /// the top, and the cursor at column 3, row 1. libghostty's IME point is
    /// the middle of the cursor cell horizontally and its bottom edge.
    private let cellSize = CGSize(width: 8, height: 16)
    private let cursor = PreviewSurfaceGrid.Cell(column: 3, row: 1)
    private var imePoint: CGPoint {
        CGPoint(x: 2 + 3 * 8 + 4, y: 4 + 2 * 16)
    }

    private func cell(at point: CGPoint) -> PreviewSurfaceGrid.Cell? {
        PreviewSurfaceGrid.cell(
            at: point, imePoint: imePoint, cursor: cursor,
            grid: .init(cellSize: cellSize, columns: 40, rows: 4)
        )
    }

    @Test
    func clickResolvesToTheCellUnderThePointer() {
        #expect(cell(at: CGPoint(x: 2, y: 4)) == .init(column: 0, row: 0))
        #expect(cell(at: CGPoint(x: 2 + 8 * 10 + 7.9, y: 4 + 16 * 2 + 1)) == .init(column: 10, row: 2))
        #expect(cell(at: CGPoint(x: 2 + 3 * 8, y: 4 + 16)) == cursor)
    }

    @Test
    func clickOutsideTheGridResolvesToNothing() {
        #expect(cell(at: CGPoint(x: 1, y: 10)) == nil)
        #expect(cell(at: CGPoint(x: 10, y: 3)) == nil)
        #expect(cell(at: CGPoint(x: 2 + 8 * 40, y: 10)) == nil)
        #expect(cell(at: CGPoint(x: 10, y: 4 + 16 * 4)) == nil)
    }

    @Test
    func noCellBeforeTheFontIsMeasured() {
        let cell = PreviewSurfaceGrid.cell(
            at: CGPoint(x: 10, y: 10), imePoint: imePoint, cursor: cursor,
            grid: .init(cellSize: .zero, columns: 40, rows: 4)
        )
        #expect(cell == nil)
    }

    @Test
    func moveCursorIsAOneBasedCursorPosition() {
        #expect(PreviewSurfaceText.moveCursor(to: .init(column: 0, row: 0)) == "\u{1B}[1;1H")
        #expect(PreviewSurfaceText.moveCursor(to: .init(column: 12, row: 3)) == "\u{1B}[4;13H")
    }

    @Test
    func scrollTextHidesTheCursorAndHasEveryLine() {
        let text = PreviewSurfaceText.scroll()
        #expect(text.hasPrefix("\u{1B}[?25l"))
        #expect(text.components(separatedBy: "\r\n").count == PreviewSurfaceText.scrollLineCount)
    }

    @Test
    func cursorTextLeavesTheCursorOnTheNextRow() {
        let text = PreviewSurfaceText.cursor()
        #expect(text.bytes.hasSuffix("\u{1B}[2;1H"))
        #expect(text.cursor == .init(column: 0, row: 1))
    }

    @Test
    func scrollPreviewSitsInAPaneScrollView() throws {
        let container = PreviewSurfaceContainer(kind: .scroll)
        let scroll = try #require(container.subviews.first as? SurfaceScrollView)
        #expect(scroll.surfaceView === container.preview)
    }

    @Test
    func cursorPreviewHasNoScrollView() {
        let container = PreviewSurfaceContainer(kind: .cursor)
        #expect(container.subviews.count == 1)
        #expect(container.subviews.first === container.preview)
    }

    @Test
    func containerRepaintsOnAConfigChange() async throws {
        let container = PreviewSurfaceContainer(kind: .cursor)
        container.layer?.backgroundColor = nil
        container.layer?.borderColor = nil
        NotificationCenter.default.post(name: .mactermConfigDidChange, object: nil)
        // The observer runs on the main queue: wait for it, with a sleep so
        // the queue gets its turn.
        for _ in 0 ..< 100 where container.layer?.backgroundColor == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(container.layer?.backgroundColor == GhosttyApp.shared.backgroundColor.cgColor)
    }

    @Test
    func containerPaintsTheThemeBackground() {
        let container = PreviewSurfaceContainer(kind: .cursor)
        container.updateLayer()
        #expect(container.layer?.backgroundColor == GhosttyApp.shared.backgroundColor.cgColor)
        #expect(container.layer?.borderColor == MactermTheme.nsBorder.cgColor)
    }

    @Test
    func containerHasAThemeEdge() {
        let container = PreviewSurfaceContainer(kind: .scroll)
        container.updateLayer()
        #expect(container.layer?.borderWidth == 1)
        #expect(container.layer?.borderColor == MactermTheme.nsBorder.cgColor)
    }
}
