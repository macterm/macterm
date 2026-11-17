import SwiftUI

/// Settings → Intelligence: the features that learn from what the user does,
/// and Apple Intelligence. Listed only on macOS 26 and later
/// (`SettingsPane.visible`).
struct IntelligenceSettings: View {
    @State
    private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section {
                // It links the Project Insights page, the only feature in the
                // pane, so that section has no docs button of its own.
                SettingsInfoPanel(
                    symbol: "apple.intelligence",
                    title: String(localized: "Intelligence", comment: "Settings pane"),
                    caption: String(
                        localized: """
                        These features need Apple Intelligence. Apple's on-device model does all the work, so \
                        nothing leaves this Mac.
                        """
                    ),
                    docs: .projectInsights
                )
            }

            Section {
                Toggle(isOn: projectInsights) {
                    Text("Enable Project Insights").dimsWhenDisabled()
                    Text(projectInsightsCaption).settingsDescription()
                }
                .disabled(!modelIsAvailable)
            } header: {
                Text("Project Insights")
            }

            Section("Apple Intelligence") {
                LabeledContent("On-device model") {
                    Text(modelStatus)
                }
            }
        }
        .formStyle(.grouped)
        // Macterm also reads it again on each activation
        // (`ProjectMemory.attach`): the user turns Apple Intelligence on in
        // System Settings.
        .onAppear {
            ProjectMemory.shared.refreshModelAvailability()
        }
    }

    /// Project Insights needs Apple Intelligence. Without it the toggle is
    /// disabled, dimmed and off, its caption ends with the reason, and
    /// `Preferences.projectMemory` keeps the user's choice for when Apple
    /// Intelligence is back.
    private var modelIsAvailable: Bool {
        ProjectMemory.shared.modelAvailability == .available
    }

    private var projectInsights: Binding<Bool> {
        Binding(
            get: { modelIsAvailable && preferences.projectMemory },
            set: { preferences.projectMemory = $0 }
        )
    }

    /// The description, and after it the reason when the model is not
    /// available, in one caption.
    private var projectInsightsCaption: String {
        let description = String(
            localized: "Shows where you left off in each project, its Git branches, and the commands to run next."
        )
        guard !modelIsAvailable else { return description }
        return String(
            localized: "settings.intelligence.projectInsights.unavailableCaption",
            defaultValue: "\(description) \(modelStatus).",
            comment: "The description of Project Insights, then the reason that it is not available."
        )
    }

    private var modelStatus: String {
        switch ProjectMemory.shared.modelAvailability {
        case .available: String(localized: "Available")
        case .notReady: String(localized: "Turn on Apple Intelligence in System Settings")
        case .unsupported: String(localized: "Not available on this Mac")
        }
    }
}
