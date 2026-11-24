import AppKit
import SwiftUI

/// The tab's split tree, laid out at card scale with the branches' real
/// ratios, so a 2x2 grid looks like a 2x2 grid. Each leaf draws its pane's
/// last live preview (`PanePreviewSampler`). The tab switcher's cards and the
/// project screen's cards both draw a tab with it.
struct TabPreviewMosaic: View {
    let node: SplitNode

    /// Gap between panes — the miniature of the split divider. Enough to read
    /// as a division at this scale without eating the previews.
    private static let gap: CGFloat = 2

    var body: some View {
        switch node {
        case let .pane(pane):
            TabPreviewMosaicLeaf(pane: pane)
        case let .split(branch):
            GeometryReader { geo in
                let ratio = min(max(branch.ratio, 0.05), 0.95)
                switch branch.direction {
                case .horizontal:
                    let first = max(0, (geo.size.width - Self.gap) * ratio)
                    HStack(spacing: Self.gap) {
                        TabPreviewMosaic(node: branch.first)
                            .frame(width: first)
                        TabPreviewMosaic(node: branch.second)
                    }
                case .vertical:
                    let first = max(0, (geo.size.height - Self.gap) * ratio)
                    VStack(spacing: Self.gap) {
                        TabPreviewMosaic(node: branch.first)
                            .frame(height: first)
                        TabPreviewMosaic(node: branch.second)
                    }
                }
            }
        }
    }
}

struct TabPreviewMosaicLeaf: View {
    let pane: Pane

    @Environment(AppState.self)
    private var appState

    var body: some View {
        let preview = appState.panePreviews[pane.id]
        // The pane's background is what defines this leaf's size. The preview
        // goes in an `overlay`, never in the layout: a `resizable` image sized
        // `.fill` reports its own (full-frame) dimensions, so as a ZStack child
        // it grew the leaf past its frame and carried the name chip out of the
        // clipped area with it — the chips were being drawn below the card.
        Rectangle()
            .fill(Color(nsColor: preview?.background ?? MactermTheme.nsBg))
            .overlay(alignment: .topLeading) {
                if let image = preview?.image {
                    // `.fit`, never `.fill`: the leaf's box already has this
                    // pane's real proportions (the mosaic is laid out at the
                    // pane region's aspect), so the frame lands in it whole.
                    // Cropping here is what made an earlier cut of this show
                    // only the top half of every tall pane.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .clipped()
    }
}
