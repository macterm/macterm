import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "GUIStateStore")

/// What only the GUI keeps (design/010 §2): the windows, the pinned records,
/// the desktop widgets' geometry. The server keeps the projects, the tabs
/// and the panes in `model.json`. Each record meets the model by an id (a
/// tab id, a project id): no second name (design/010 §11, §3).
struct GUIStateFile: Codable {
    var version: Int
    /// The open windows, in creation order.
    var windows: [WindowSnapshot]?
    /// The pinned records, in sidebar order: the declaration and the origin
    /// of each tab, by tab id. A record whose tab is not in the pinned
    /// project is unloaded.
    var pinned: [PinnedRecordState]?
    /// The desktop widgets' geometry and recipe, by widget id, which is the
    /// id of the widget's project.
    var desktopWidgets: [DesktopWidgetState]?
}

/// One pinned record (`PinnedTabRecord`), with no live tab.
struct PinnedRecordState: Codable {
    let id: UUID
    let declaration: LayoutTab
    let originProjectID: UUID?
}

/// One desktop widget (`DesktopWidget`), with no tab: its tab is in the
/// widget's project on the server.
struct DesktopWidgetState: Codable {
    var id: UUID
    var name: String?
    var columns: Int
    var rows: Int
    var topLeftX: Double
    var topLeftY: Double
    var command: String?
    var cwd: String?
    var placements: [DesktopWidgetPlacement]?
}

/// `gui-state.json` in the folder of the v1 files. A file that does not
/// read, or that a newer build wrote, is never written over (the
/// `loadFailed` rule of v1).
final class GUIStateStore {
    static let currentVersion = 1
    private let fileURL: URL
    private(set) var loadFailed = false
    /// Whether a file was there to load.
    private(set) var existed = false

    init(fileURL: URL = FileStorage.fileURL(filename: "gui-state.json")) {
        self.fileURL = fileURL
    }

    func load() -> GUIStateFile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        existed = true
        do {
            let data = try Data(contentsOf: fileURL)
            if data.isEmpty { return nil }
            let file = try JSONDecoder().decode(GUIStateFile.self, from: data)
            guard file.version <= Self.currentVersion else {
                logger.error("gui-state.json v\(file.version, privacy: .public) is newer than this build; not overwriting")
                loadFailed = true
                return file
            }
            return file
        } catch {
            logger.error("gui-state.json does not read: \(String(describing: error), privacy: .public)")
            loadFailed = true
            return nil
        }
    }

    func save(_ file: GUIStateFile) {
        guard !loadFailed else {
            logger.error("Refusing to save gui-state.json: it did not read")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save gui-state.json: \(String(describing: error), privacy: .public)")
        }
    }
}
