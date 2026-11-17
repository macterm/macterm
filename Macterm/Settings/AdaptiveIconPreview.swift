import AppKit
import SwiftUI

/// The last rows of Settings → Appearance → App Icon: the icon that the Dock
/// shows for the current setting, theme and system state, and the line that
/// says why it is not in the theme's colors.
///
/// The images are the ones the app gives the Dock (`AdaptiveIconController`),
/// never a copy drawn here. While a side renders, its tile keeps its last
/// image, with no spinner.
struct AdaptiveIconPreview: View {
    private let controller = AdaptiveIconController.shared

    /// The icon's side on screen, in points.
    static let iconSize: CGFloat = 96

    var body: some View {
        let preview = controller.preview
        HStack(spacing: 24) {
            ForEach(Array(preview.icons.enumerated()), id: \.offset) { _, icon in
                VStack(spacing: 4) {
                    Group {
                        if let image = icon.image {
                            Image(nsImage: image).resizable().interpolation(.high)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("App icon preview"))
        .onAppear { controller.previewShown = true }
        .onDisappear { controller.previewShown = false }

        if let line = preview.standIn?.previewLine {
            Text(line).settingsSecondaryText()
        }
    }

    private func label(for appearance: AdaptiveIconRequest.Appearance) -> Text {
        switch appearance {
        case .light: Text("Light", comment: "Under the light version of the app icon in Settings → Appearance.")
        case .dark: Text("Dark", comment: "Under the dark version of the app icon in Settings → Appearance.")
        }
    }
}
