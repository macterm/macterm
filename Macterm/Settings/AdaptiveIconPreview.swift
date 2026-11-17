import AppKit
import SwiftUI

/// The first row of Settings → Appearance → App Icon, above the toggle: the
/// icon that the Dock shows for the current setting, theme and system state.
///
/// The images are the ones the app gives the Dock (`AdaptiveIconController`),
/// never a copy drawn here. While a side renders, its tile keeps its last
/// image, with no spinner. In a Clear or Tinted icon style it shows no icon
/// (`AdaptiveIcon.StandIn.showsIcon`). `AdaptiveIconPreview.Footnote` is the
/// line that says why the icon is not in the theme's colors.
struct AdaptiveIconPreview: View {
    private let controller = AdaptiveIconController.shared

    /// The icon's side on screen, in points.
    static let iconSize: CGFloat = 96

    var body: some View {
        let preview = controller.preview
        // No row at all in a Clear or Tinted style: an empty row would show a gap.
        if !preview.icons.isEmpty {
            HStack(spacing: 24) {
                ForEach(Array(preview.icons.enumerated()), id: \.offset) { _, icon in
                    VStack(spacing: 4) {
                        Group {
                            if let image = icon.image {
                                Image(nsImage: image).resizable().interpolation(.high).accessibilityHidden(true)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: Self.iconSize, height: Self.iconSize)
                        if preview.icons.count > 1, let appearance = icon.appearance {
                            label(for: appearance).settingsSecondaryText()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("App icon preview"))
            .onAppear { controller.previewShown = true }
            .onDisappear { controller.previewShown = false }
        }
    }

    private func label(for appearance: AdaptiveIconRequest.Appearance) -> Text {
        switch appearance {
        case .light: Text("Light", comment: "Under the light version of the app icon in Settings → Appearance.")
        case .dark: Text("Dark", comment: "Under the dark version of the app icon in Settings → Appearance.")
        }
    }

    /// The last row of the section: why the preview is not in the theme's
    /// colors (`AdaptiveIcon.StandIn.previewLine`), or nothing.
    struct Footnote: View {
        private let controller = AdaptiveIconController.shared

        var body: some View {
            if let line = controller.preview.standIn?.previewLine {
                Text(line).settingsSecondaryText()
            }
        }
    }
}
