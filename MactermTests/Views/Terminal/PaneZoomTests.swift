import CoreGraphics
@testable import Macterm
import Testing

/// The zoom of a pane's picture: the pinch about the pointer, the 1x to 3x
/// clamp, the pan that keeps the pane covered and hands its rest to the
/// scroll, and the whole-pixel scale that libghostty draws.
struct PaneZoomTests {
    private let size = CGSize(width: 800, height: 600)

    @Test
    func a_new_zoom_is_the_identity() {
        let zoom = PaneZoom()
        #expect(zoom.isIdentity)
        #expect(zoom.scale == 1)
        #expect(zoom.offset == .zero)
    }

    @Test
    func a_pinch_keeps_the_point_under_the_pointer() {
        var zoom = PaneZoom()
        let point = CGPoint(x: 300, y: 200)
        zoom.pinch(by: 1, at: point, in: size)
        #expect(zoom.scale == 2)
        // The base point under the pointer still draws under the pointer.
        #expect(zoom.scale * point.x + zoom.offset.x == point.x)
        #expect(zoom.scale * point.y + zoom.offset.y == point.y)
    }

    @Test
    func the_scale_stays_between_1x_and_3x() {
        var zoom = PaneZoom()
        zoom.pinch(by: -0.5, at: CGPoint(x: 10, y: 10), in: size)
        #expect(zoom.isIdentity)
        for _ in 0 ..< 20 {
            zoom.pinch(by: 0.5, at: CGPoint(x: 400, y: 300), in: size)
        }
        #expect(zoom.scale == PaneZoom.maxScale)
        zoom.pinch(by: -0.99, at: CGPoint(x: 400, y: 300), in: size)
        #expect(zoom.isIdentity)
    }

    @Test
    func a_pinch_that_is_not_finite_changes_nothing() {
        var zoom = PaneZoom()
        zoom.pinch(by: 1, at: CGPoint(x: 100, y: 100), in: size)
        let before = zoom
        zoom.pinch(by: .nan, at: CGPoint(x: 100, y: 100), in: size)
        #expect(zoom == before)
    }

    @Test
    func a_pinch_at_the_edge_keeps_the_pane_covered() {
        var zoom = PaneZoom()
        // A pinch about a point outside the pane would pull the picture off
        // its edge: the clamp keeps it covering the pane.
        zoom.pinch(by: 1, at: CGPoint(x: -400, y: 900), in: size)
        #expect(zoom.offset.x <= 0)
        #expect(zoom.offset.y <= 0)
        #expect(zoom.scale * size.width + zoom.offset.x >= size.width)
        #expect(zoom.scale * size.height + zoom.offset.y >= size.height)
    }

    @Test
    func a_pan_moves_the_picture_and_returns_nothing_inside_the_edges() {
        var zoom = PaneZoom()
        zoom.pinch(by: 1, at: CGPoint(x: 400, y: 300), in: size)
        let before = zoom.offset
        let leftover = zoom.pan(by: CGSize(width: 50, height: -40), in: size)
        #expect(leftover == .zero)
        #expect(zoom.offset.x == before.x + 50)
        #expect(zoom.offset.y == before.y - 40)
    }

    @Test
    func a_pan_past_the_edge_returns_the_rest_for_the_scroll() {
        var zoom = PaneZoom()
        zoom.pinch(by: 1, at: CGPoint(x: 400, y: 300), in: size)
        // The top edge is 300 pt away: 100 pt more scrolls the terminal.
        let leftover = zoom.pan(by: CGSize(width: 0, height: 400), in: size)
        #expect(zoom.offset.y == 0)
        #expect(leftover == CGSize(width: 0, height: 100))
        // At the edge, a pan the same way is all scroll.
        #expect(zoom.pan(by: CGSize(width: 0, height: 30), in: size) == CGSize(width: 0, height: 30))
        // A pan the other way moves the picture again.
        #expect(zoom.pan(by: CGSize(width: 0, height: -30), in: size) == .zero)
        #expect(zoom.offset.y == -30)
    }

    @Test
    func at_1x_every_pan_is_scroll() {
        var zoom = PaneZoom()
        let delta = CGSize(width: 12, height: -7)
        #expect(zoom.pan(by: delta, in: size) == delta)
        #expect(zoom.isIdentity)
    }

    @Test
    func a_smaller_pane_clamps_the_pan_again() {
        var zoom = PaneZoom()
        zoom.pinch(by: 1, at: CGPoint(x: 800, y: 600), in: size)
        #expect(zoom.offset == CGPoint(x: -800, y: -600))
        let smaller = zoom.clamped(to: CGSize(width: 400, height: 300))
        #expect(smaller.offset == CGPoint(x: -400, y: -300))
        #expect(smaller.scale == 2)
    }

    @Test
    func the_drawn_scale_is_a_whole_pixel_cell_on_each_axis() {
        var zoom = PaneZoom()
        zoom.pinch(by: 0.1, at: .zero, in: size)
        // A 16x34 pixel cell at 1.1x draws as 18x37 (design/012, E4).
        let drawn = zoom.drawn(cellPixels: CGSize(width: 16, height: 34), in: size)
        #expect(drawn.scaleX == CGFloat(18) / 16)
        #expect(drawn.scaleY == CGFloat(37) / 34)
        #expect(drawn.offsetX <= 0)
        #expect(drawn.scaleX * size.width + drawn.offsetX >= size.width)
        #expect(drawn.scaleY * size.height + drawn.offsetY >= size.height)
    }

    @Test
    func the_identity_draws_as_the_identity() {
        let drawn = PaneZoom().drawn(cellPixels: CGSize(width: 16, height: 34), in: size)
        #expect(drawn == .identity)
    }

    @Test
    func the_map_from_a_frame_to_its_own_zoom_is_the_identity() {
        var zoom = PaneZoom()
        zoom.pinch(by: 0.7, at: CGPoint(x: 120, y: 450), in: size)
        let drawn = zoom.drawn(cellPixels: CGSize(width: 16, height: 34), in: size)
        #expect(PaneZoom.map(from: drawn, to: drawn) == .identity)
    }

    @Test
    func the_map_takes_each_drawn_point_to_its_new_place() {
        let cell = CGSize(width: 16, height: 34)
        var old = PaneZoom()
        old.pinch(by: 0.5, at: CGPoint(x: 200, y: 100), in: size)
        var new = old
        new.pinch(by: 0.4, at: CGPoint(x: 600, y: 500), in: size)
        let from = old.drawn(cellPixels: cell, in: size)
        let to = new.drawn(cellPixels: cell, in: size)
        let map = PaneZoom.map(from: from, to: to)
        // A base point p drew at from(p); the map moves it to to(p).
        let p = CGPoint(x: 333, y: 222)
        let x = map.scaleX * (from.scaleX * p.x + from.offsetX) + map.offsetX
        let y = map.scaleY * (from.scaleY * p.y + from.offsetY) + map.offsetY
        #expect(abs(x - (to.scaleX * p.x + to.offsetX)) < 1e-9)
        #expect(abs(y - (to.scaleY * p.y + to.offsetY)) < 1e-9)
    }
}
