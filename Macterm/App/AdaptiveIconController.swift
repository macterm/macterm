import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "AdaptiveIconController")

/// Keeps the Dock icon on what `AdaptiveIcon.decide` asks for: the bundled
/// icon, the user's custom image, or the bundled icon repainted in the theme.
///
/// `GhosttyApp` hands it the config's choice on every load and reload; the
/// theme colors, the system's appearance and icon style and the preference
/// are read again on each `refresh`, which runs on every config change, when
/// the app becomes active (System Settings sends no notice when the icon
/// style changes) and when the preference changes. A refresh whose request is
/// the one already shown or in flight does nothing, so the frequent config
/// notifications cost a few color reads.
///
/// The repainted icon is rendered by `AdaptiveIconRenderer` in a helper
/// process. While a render is in flight the Dock keeps what it shows. A
/// render that fails puts the bundled icon back and turns the adaptive icon
/// off for the rest of the run: a failure there means the private renderer
/// changed under this build, and it will not start working again until the
/// next launch.
///
/// It also keeps `preview`, the icons that Settings → Appearance shows: the
/// image that the Dock gets, and the other appearance's while the preview is
/// on screen (`previewShown`).
@MainActor @Observable
final class AdaptiveIconController {
    static let shared = AdaptiveIconController()

    /// One icon of the preview in Settings.
    struct PreviewIcon: Equatable {
        /// Nil for the configured icon, which has one image for both sides.
        var appearance: AdaptiveIconRequest.Appearance?
        /// Nil until the first image of this side exists: the tile stays
        /// empty, with no spinner.
        var image: NSImage?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.appearance == rhs.appearance && lhs.image === rhs.image
        }
    }

    /// What the preview in Settings shows: the Dock's icon for the current
    /// state, and why it is not in the theme's colors (`StandIn.previewLine`).
    struct Preview: Equatable {
        var icons: [PreviewIcon] = []
        var standIn: AdaptiveIcon.StandIn?
    }

    private(set) var preview = Preview()

    /// Whether the preview is on screen. Only then does the controller
    /// render the appearance that the Dock does not show.
    var previewShown = false {
        didSet {
            guard previewShown != oldValue else { return }
            refresh()
        }
    }

    @ObservationIgnored
    private var configured: GhosttyAppIcon = .bundled
    /// The request shown or in flight, nil while the Dock shows `configured`.
    @ObservationIgnored
    private var current: AdaptiveIconRequest?
    /// The renders for the Dock that run or wait. A render for the preview
    /// starts only at zero, so that it never takes the Dock's place in the
    /// queue.
    @ObservationIgnored
    private var dockRenders = 0
    /// The render for the preview that runs or waits, so a refresh does not
    /// queue the same request again.
    @ObservationIgnored
    private var previewRender: AdaptiveIconRequest?
    /// The last request for the preview that the helper failed. It is not
    /// tried again, and it never turns off the Dock's icon: only the Dock's
    /// own render does that.
    @ObservationIgnored
    private var previewFailed: AdaptiveIconRequest?
    /// The request for the appearance that only the preview shows, nil when
    /// the preview shows no such side.
    @ObservationIgnored
    private var previewOnly: AdaptiveIconRequest?
    /// Bumped by every refresh that changes course, so a render that ends
    /// after a newer one began is dropped.
    @ObservationIgnored
    private var generation = 0
    /// Why the adaptive icon is off for this run, once a render failed.
    @ObservationIgnored
    private var suspension: AdaptiveIconRenderer.Failure?
    /// What the last refresh decided, for `note`.
    @ObservationIgnored
    private var lastOutcome: String?
    /// The images of this run, one for each appearance, so a light/dark
    /// switch back to a seen request installs at once.
    @ObservationIgnored
    private var rendered: [AdaptiveIconRequest.Appearance: (request: AdaptiveIconRequest, image: NSImage)] = [:]
    @ObservationIgnored
    private let cache = AdaptiveIconCache(directory: FileStorage.appSupportDirectory().appendingPathComponent(
        "AdaptiveIcon",
        isDirectory: true
    ))
    /// One helper at a time: a burst of theme changes queues only the last.
    @ObservationIgnored
    private let renders = AdaptiveIconRenderer.Queue()
    @ObservationIgnored
    private var observers: [any NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .mactermConfigDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AdaptiveIconController.shared.refresh() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AdaptiveIconController.shared.refresh() }
        })
    }

    /// The ghostty config's `macos-icon` choice, from `GhosttyApp`. The
    /// refresh waits one main-queue turn: the first call comes from inside
    /// `GhosttyApp.init`, and `refresh` reads `GhosttyApp.shared`, which
    /// would deadlock its dispatch_once there.
    func configuredIconDidChange(_ icon: GhosttyAppIcon) {
        configured = icon
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AdaptiveIconController.shared.refresh() }
        }
    }

    func refresh() {
        switch adaptiveRequest() {
        case let .configured(standIn):
            showConfigured()
            showPreview(of: standIn)
        case let .adaptive(request, paint):
            note("on (\(request.appearance.rawValue))")
            showDock(request)
            showPreview(of: request, paint: paint)
        }
    }

    private func showDock(_ request: AdaptiveIconRequest) {
        guard request != current else { return }
        current = request
        generation += 1

        if let image = knownImage(for: request) {
            AppIconPresenter.applyAdaptive(image)
            return
        }
        logger.info("rendering the adaptive icon (\(request.appearance.rawValue, privacy: .public))")
        render(request, generation: generation)
    }

    /// The image of this request from this run or from the disk, nil when
    /// it needs a render.
    private func knownImage(for request: AdaptiveIconRequest) -> NSImage? {
        if let seen = rendered[request.appearance], seen.request == request { return seen.image }
        guard let image = cache.image(for: request) else { return nil }
        remember(image, for: request)
        logger.info("adaptive icon (\(request.appearance.rawValue, privacy: .public)) taken from the cache")
        return image
    }

    // MARK: - Preview

    /// The Dock shows the configured icon: the preview shows the same image.
    private func showPreview(of standIn: AdaptiveIcon.StandIn) {
        previewOnly = nil
        // A custom image that cannot be read leaves the bundled icon, and
        // the line about the key would then be wrong.
        let standIn = standIn == .customIcon && !AppIconPresenter.showsCustomImage ? .unavailable : standIn
        setPreview(Preview(icons: [PreviewIcon(appearance: nil, image: NSApp.applicationIconImage)], standIn: standIn))
    }

    /// The Dock shows the adaptive icon. While a side renders, its tile keeps
    /// the last image of that side.
    private func showPreview(of shown: AdaptiveIconRequest, paint: AdaptiveIcon.Paint) {
        let iconStyle = Self.iconStyle()
        let appearances = previewShown
            ? AdaptiveIcon.previewAppearances(
                shown: shown.appearance,
                iconStyle: iconStyle,
                themeHasTwoSides: GhosttyApp.shared.themeHasTwoSides
            )
            : [shown.appearance]
        previewOnly = appearances.first { $0 != shown.appearance }.flatMap { request(for: $0, paint: paint) }
        var icons: [PreviewIcon] = []
        for appearance in appearances {
            let request = appearance == shown.appearance ? shown : previewOnly
            var image = request.flatMap { knownImage(for: $0) } ?? rendered[appearance]?.image
            // The Dock keeps its icon while its new one renders.
            if image == nil, appearance == shown.appearance { image = NSApp.applicationIconImage }
            icons.append(PreviewIcon(appearance: appearance, image: image))
        }
        setPreview(Preview(icons: icons, standIn: nil))
        renderPreviewOnlySide()
    }

    /// A refresh that changes nothing does not redraw the preview.
    private func setPreview(_ new: Preview) {
        guard new != preview else { return }
        preview = new
    }

    /// Renders the side that only the preview shows, after the Dock's render.
    private func renderPreviewOnlySide() {
        guard let request = previewOnly, dockRenders == 0, previewRender != request, previewFailed != request,
              knownImage(for: request) == nil
        else { return }
        previewRender = request
        renders.render(request) { [self] result in
            if previewRender == request { previewRender = nil }
            guard case let .success(png) = result, let image = NSImage(data: png) else {
                // The tile keeps its last image. `.superseded` says nothing.
                if case let .failure(failure) = result, failure == .superseded { return }
                previewFailed = request
                logger.warning("the preview's adaptive icon (\(request.appearance.rawValue, privacy: .public)) did not render")
                return
            }
            guard request == previewOnly else { return }
            remember(image, for: request)
            cache.store(png, for: request)
            refresh()
        }
    }

    private static func iconStyle() -> String? {
        CFPreferencesCopyAppValue(AdaptiveIcon.iconStyleKey as CFString, kCFPreferencesAnyApplication) as? String
    }

    private enum Outcome {
        case configured(AdaptiveIcon.StandIn)
        case adaptive(AdaptiveIconRequest, AdaptiveIcon.Paint)
    }

    /// The request for the adaptive icon and its paint, or why the Dock shows
    /// the configured icon. Each stand-in says why in the log.
    private func adaptiveRequest() -> Outcome {
        let iconStyle = Self.iconStyle()
        let enabled = Preferences.shared.adaptiveIcon
        let supported = AdaptiveIcon.isSupported
        let decision = AdaptiveIcon.decide(
            enabled: enabled,
            supported: supported && suspension == nil,
            configured: configured,
            iconStyle: iconStyle,
            systemScheme: { GhosttyApp.shared.systemScheme }
        )
        let appearance: AdaptiveIconRequest.Appearance
        switch decision {
        case let .configured(_, standIn):
            let suspended = suspension != nil
            let style = iconStyle ?? "none"
            note("off (enabled \(enabled), supported \(supported), suspended \(suspended), configured \(configured), icon style \(style))")
            return .configured(standIn)
        case let .adaptive(side):
            appearance = side
        }
        guard let theme = themeColors() else {
            note("off (a theme color cannot be read)")
            return .configured(.unavailable)
        }
        guard let paint = AdaptiveIcon.paint(for: theme) else {
            note("off (the theme has no gray for the lid)")
            return .configured(.noLidGray)
        }
        guard let request = request(for: appearance, paint: paint) else {
            note("off (the bundle has no Assets.car)")
            return .configured(.unavailable)
        }
        return .adaptive(request, paint)
    }

    /// Logs what a refresh decided, once for each change: a refresh runs on
    /// every config change and activation.
    private func note(_ outcome: String) {
        guard outcome != lastOutcome else { return }
        lastOutcome = outcome
        logger.info("adaptive icon \(outcome, privacy: .public)")
    }

    private func showConfigured() {
        if current != nil {
            generation += 1
            logger.info("adaptive icon off, showing the configured icon")
        }
        current = nil
        AppIconPresenter.apply(configured)
    }

    private func render(_ request: AdaptiveIconRequest, generation: Int) {
        let started = ContinuousClock.now
        dockRenders += 1
        renders.render(request) { [self] result in
            dockRenders -= 1
            defer { renderPreviewOnlySide() }
            guard generation == self.generation else { return }
            switch result {
            case let .success(png):
                guard let image = NSImage(data: png) else { return fail(.notAnImage) }
                remember(image, for: request)
                cache.store(png, for: request)
                AppIconPresenter.applyAdaptive(image)
                refresh()
                let elapsed = started.duration(to: .now)
                logger.info("adaptive icon (\(request.appearance.rawValue, privacy: .public)) rendered in \(elapsed, privacy: .public)")
            case .failure(.superseded):
                // A newer request took this one's place. It says nothing
                // about the helper, so it suspends nothing.
                return
            case let .failure(failure):
                fail(failure)
            }
        }
    }

    private func fail(_ failure: AdaptiveIconRenderer.Failure) {
        suspension = failure
        logger.error("adaptive icon off for this run, keeping the bundled icon: \(failure.description, privacy: .public)")
        refresh()
    }

    private func remember(_ image: NSImage, for request: AdaptiveIconRequest) {
        rendered[request.appearance] = (request, image)
    }

    /// The colors the icon is painted from, nil when one cannot be read.
    private func themeColors() -> AdaptiveIcon.ThemeColors? {
        let app = GhosttyApp.shared
        func color(_ color: NSColor?) -> AdaptiveIcon.Color? {
            guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
            return .init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        }
        guard let background = color(app.backgroundColor) else { return nil }
        var palette: [AdaptiveIcon.Color] = []
        for index in 0 ..< 16 {
            guard let entry = color(app.paletteColor(at: index)) else { return nil }
            palette.append(entry)
        }
        return .init(background: background, palette: palette)
    }

    /// The request for this paint, or nil when the bundle has no compiled
    /// catalog to paint.
    private func request(for appearance: AdaptiveIconRequest.Appearance, paint: AdaptiveIcon.Paint) -> AdaptiveIconRequest? {
        guard let catalog = Bundle.main.url(forResource: "Assets", withExtension: "car") else { return nil }
        return AdaptiveIconRequest(
            catalogPath: catalog.path,
            iconName: Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String ?? "AppIcon",
            appearance: appearance,
            backgroundTop: paint.backgroundTop,
            backgroundBottom: paint.backgroundBottom,
            layers: paint.layers,
            accents: paint.accents,
            pixels: 1024
        )
    }
}

/// The last adaptive icon of each appearance, on disk, so a launch shows the
/// theme's icon at once instead of the bundled icon for the length of a
/// render. An entry counts only for the same request from the same build: the
/// stamp names the app's build and the catalog's size and date, so an update
/// that changes the icon renders again.
struct AdaptiveIconCache {
    let directory: URL

    private struct Entry: Codable, Equatable {
        var request: AdaptiveIconRequest
        var stamp: String
    }

    func image(for request: AdaptiveIconRequest) -> NSImage? {
        guard let data = try? Data(contentsOf: entryURL(request.appearance)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry == Entry(request: request, stamp: Self.stamp(catalogPath: request.catalogPath)),
              let png = try? Data(contentsOf: imageURL(request.appearance)),
              let image = NSImage(data: png), image.isValid
        else { return nil }
        return image
    }

    func store(_ png: Data, for request: AdaptiveIconRequest) {
        let entry = Entry(request: request, stamp: Self.stamp(catalogPath: request.catalogPath))
        guard let json = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: imageURL(request.appearance), options: .atomic)
            try json.write(to: entryURL(request.appearance), options: .atomic)
        } catch {
            logger.warning("cannot keep the adaptive icon on disk: \(EnglishErrorText.describe(error), privacy: .public)")
        }
    }

    static func stamp(catalogPath: String) -> String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let attributes = try? FileManager.default.attributesOfItem(atPath: catalogPath)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(build) \(size) \(date)"
    }

    private func entryURL(_ appearance: AdaptiveIconRequest.Appearance) -> URL {
        directory.appendingPathComponent("\(appearance.rawValue).json")
    }

    private func imageURL(_ appearance: AdaptiveIconRequest.Appearance) -> URL {
        directory.appendingPathComponent("\(appearance.rawValue).png")
    }
}
