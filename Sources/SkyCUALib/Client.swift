import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Options for client construction (spec: RequestOptions).
public struct SkyClientOptions: Sendable {
    /// Per-action timeout in seconds (spec default 5s on their transport;
    /// in-process calls use it as the AX/CGEvent budget).
    public var timeoutSeconds: Double
    /// Disable screenshot capture in getAppState.
    public var disableScreenshots: Bool
    /// Directory for captured skyshot PNGs.
    public var screenshotDirectory: URL?

    public init(
        timeoutSeconds: Double = 30,
        disableScreenshots: Bool = false,
        screenshotDirectory: URL? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.disableScreenshots = disableScreenshots
        self.screenshotDirectory = screenshotDirectory
    }
}

/// Clean-room implementation of the MacComputerUseClient surface on public
/// macOS APIs. All actions pass through the policy gate before execution.
public final class SkyMacComputerUseClient: @unchecked Sendable {

    /// Snapshot cache: latest AX snapshot per resolved app id.
    private var snapshots: [String: SkyAXSnapshot] = [:]
    private var snapshotLock = NSLock()
    /// Apps that already received app-specific instructions (spec behavior).
    private var instructionsDelivered: Set<String> = []
    private let options: SkyClientOptions
    private let policy: SkyPolicyStore
    private let pasteboardWrapper = SkyPasteboard()

    public init(
        options: SkyClientOptions = SkyClientOptions(),
        policy: SkyPolicyStore = .shared
    ) {
        self.options = options
        self.policy = policy
    }

    // MARK: - listApps

    /// List targetable apps (spec: listApps / list_apps).
    public func listApps() -> [SkyDiscoveredApp] {
        SkyAppResolver.listApps()
    }

    // MARK: - getAppPolicy

    /// Policy decision for an app (spec: getAppPolicy).
    public func getAppPolicy(_ appOrArgs: String) throws -> SkyAppPolicyResult {
        let app = try resolveForPolicy(appOrArgs)
        return policy.policy(for: app)
    }

    // MARK: - startApp

    /// Activate an app's window and return its state (spec: startApp).
    public func startApp(_ appOrArgs: String) async throws -> SkyWindowAppState {
        let target = try SkyAppResolver.resolveRunning(appOrArgs)
        _ = try? target.activate()
        // Give the activation a beat, then capture.
        try await Task.sleep(nanoseconds: 250_000_000)
        return try await getAppState(appOrArgs)
    }

    // MARK: - getAppState

    /// Capture AX tree + screenshot (spec: getAppState / get_app_state).
    public func getAppState(_ appOrArgs: String, disableDiff: Bool = false) async throws -> SkyWindowAppState {
        try await gated(appIdentifier: appOrArgs, requestType: "getAppState") { [self] target, bundleID in
            let app = try SkyAppResolver.resolveRunning(appOrArgs)
            let snapshot = try SkyAXWalker.captureApp(pid: Int(app.processIdentifier), appID: bundleID)
            storeSnapshot(bundleID, snapshot)

            var shot: SkyScreenshot? = nil
            if !options.disableScreenshots, #available(macOS 14.0, *) {
                if let capture = try? await SkyScreenshotCapture.captureWindowPNG(
                    pid: Int(app.processIdentifier),
                    outputDirectory: options.screenshotDirectory
                ) {
                    shot = SkyScreenshot(url: capture.dataURL, mimeType: "image/png")
                    _ = capture.fileURL
                }
            }

            let instructions = appSpecificInstructions(for: bundleID)
            let deliverInstructions: String? = instructionsDelivered.contains(bundleID) ? nil : instructions
            if instructions != nil {
                instructionsDelivered.insert(bundleID)
            }

            let skyshot = SkyWindowSkyshot(text: snapshot.text, screenshot: shot)
            return SkyWindowAppState(
                app: bundleID,
                appSpecificInstructions: deliverInstructions,
                skyshot: skyshot
            )
        }
    }

    // MARK: - click

    /// Click an element by index or a window-relative coordinate
    /// (spec: click).
    public func click(
        app appIdentifier: String,
        elementIndex: Int? = nil,
        x: Double? = nil,
        y: Double? = nil,
        mouseButton: SkyMouseButton = .left,
        clickCount: Int = 1
    ) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "click") { [self] target, bundleID in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            let pid = Int(app.processIdentifier)

            if let elementIndex {
                guard let snapshot = latestSnapshot(bundleID) else {
                    throw SkyComputerUseError(
                        code: 0,
                        errorName: .elementNotFound,
                        message: "No app state for '\(bundleID)'; call getAppState first.",
                        requestType: "click"
                    )
                }
                guard let node = snapshot.node(at: elementIndex) else {
                    throw SkyComputerUseError(
                        code: 0,
                        errorName: .elementNotFound,
                        message: "elementIndex \(elementIndex) out of range (0..\(snapshot.nodes.count - 1)).",
                        requestType: "click"
                    )
                }
                // Prefer AXPress when available; fall back to center click.
                if node.actions.contains("AXPress") {
                    try SkyAXActions.performSecondaryAction(
                        pid: pid_t(pid),
                        elementIndex: elementIndex,
                        action: "AXPress"
                    )
                    return
                }
                guard let frame = node.frame else {
                    throw SkyComputerUseError(
                        code: 0,
                        errorName: .elementNotFound,
                        message: "Element \(elementIndex) has no frame to click.",
                        requestType: "click"
                    )
                }
                let center = CGPoint(
                    x: frame.x + frame.width / 2,
                    y: frame.y + frame.height / 2
                )
                try activateIfNeeded(app)
                try SkyEventSynthesizer.click(at: center, button: mouseButton.canonical.type, clickCount: clickCount)
            } else if let x, let y {
                // Window-relative coordinate: offset by the window's global frame.
                guard let snapshot = latestSnapshot(bundleID), let winFrame = snapshot.windowFrame else {
                    throw SkyComputerUseError(
                        code: 0,
                        errorName: .elementNotFound,
                        message: "No window frame for '\(bundleID)'; call getAppState first.",
                        requestType: "click"
                    )
                }
                let global = CGPoint(x: winFrame.x + x, y: winFrame.y + y)
                try activateIfNeeded(app)
                try SkyEventSynthesizer.click(at: global, button: mouseButton.canonical.type, clickCount: clickCount)
            } else {
                throw SkyComputerUseError(
                    code: 0,
                    errorName: .invalidApp,
                    message: "click requires elementIndex or x/y.",
                    requestType: "click"
                )
            }
        }
    }

    // MARK: - drag

    /// Drag between window-relative coordinates (spec: drag).
    public func drag(
        app appIdentifier: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double
    ) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "drag") { [self] _, bundleID in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            guard let snapshot = latestSnapshot(bundleID), let winFrame = snapshot.windowFrame else {
                throw SkyComputerUseError(
                    code: 0,
                    errorName: .elementNotFound,
                    message: "No window frame for '\(bundleID)'; call getAppState first.",
                    requestType: "drag"
                )
            }
            try activateIfNeeded(app)
            try SkyEventSynthesizer.drag(
                from: CGPoint(x: winFrame.x + fromX, y: winFrame.y + fromY),
                to: CGPoint(x: winFrame.x + toX, y: winFrame.y + toY)
            )
        }
    }

    // MARK: - pressKey

    /// Press a key chord into the app (spec: pressKey).
    public func pressKey(app appIdentifier: String, key: String) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "pressKey") { [self] _, _ in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            try activateIfNeeded(app)
            try SkyEventSynthesizer.pressKey(key)
        }
    }

    // MARK: - typeText

    /// Type text into the app's focused element (spec: typeText).
    public func typeText(app appIdentifier: String, text: String) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "typeText") { [self] _, _ in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            try activateIfNeeded(app)
            try SkyEventSynthesizer.typeText(text)
        }
    }

    // MARK: - scroll

    /// Scroll at element/coordinate (spec: scroll). `pages` ~ 3 lines/page.
    public func scroll(
        app appIdentifier: String,
        direction: SkyDirection,
        elementIndex: Int? = nil,
        x: Double? = nil,
        y: Double? = nil,
        pages: Double = 1
    ) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "scroll") { [self] _, bundleID in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            let pid = Int(app.processIdentifier)
            try activateIfNeeded(app)

            // Resolve the scroll origin point.
            let point: CGPoint
            if let elementIndex {
                guard let snapshot = latestSnapshot(bundleID),
                      let node = snapshot.node(at: elementIndex),
                      let frame = node.frame
                else {
                    throw SkyComputerUseError(
                        code: 0,
                        errorName: .elementNotFound,
                        message: "elementIndex \(elementIndex) unresolvable; call getAppState first.",
                        requestType: "scroll"
                    )
                }
                point = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            } else if let x, let y, let snapshot = latestSnapshot(bundleID), let winFrame = snapshot.windowFrame {
                point = CGPoint(x: winFrame.x + x, y: winFrame.y + y)
            } else {
                // Center of the window.
                guard let snapshot = latestSnapshot(bundleID), let winFrame = snapshot.windowFrame else {
                    throw SkyComputerUseError(
                        code: 0,
                        errorName: .elementNotFound,
                        message: "No window frame for '\(bundleID)'.",
                        requestType: "scroll"
                    )
                }
                point = CGPoint(x: winFrame.x + winFrame.width / 2, y: winFrame.y + winFrame.height / 2)
            }

            let lines = pages * 3
            switch direction.canonical {
            case .up: try SkyEventSynthesizer.scroll(at: point, linesDown: -lines)
            case .down: try SkyEventSynthesizer.scroll(at: point, linesDown: lines)
            case .left: try SkyEventSynthesizer.scrollHorizontal(at: point, linesRight: -lines)
            case .right: try SkyEventSynthesizer.scrollHorizontal(at: point, linesRight: lines)
            case .u: try SkyEventSynthesizer.scroll(at: point, linesDown: -lines)
            case .d: try SkyEventSynthesizer.scroll(at: point, linesDown: lines)
            case .l: try SkyEventSynthesizer.scrollHorizontal(at: point, linesRight: -lines)
            case .r: try SkyEventSynthesizer.scrollHorizontal(at: point, linesRight: lines)
            }
        }
    }

    // MARK: - setValue

    /// Replace an editable element's value (spec: setValue).
    public func setValue(app appIdentifier: String, elementIndex: Int, value: String) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "setValue") { _, _ in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            try SkyAXActions.setValue(pid: app.processIdentifier, elementIndex: elementIndex, value: value)
        }
    }

    // MARK: - selectText

    /// Select matching text in an editable element (spec: selectText).
    public func selectText(
        app appIdentifier: String,
        elementIndex: Int,
        text: String,
        prefix: String? = nil,
        suffix: String? = nil,
        selection: SkySelectionType = .text
    ) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "selectText") { _, _ in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            try SkyAXActions.selectText(
                pid: app.processIdentifier,
                elementIndex: elementIndex,
                text: text,
                prefix: prefix,
                suffix: suffix,
                selection: selection
            )
        }
    }

    // MARK: - performSecondaryAction

    /// Invoke a named AX action on an indexed element
    /// (spec: performSecondaryAction).
    public func performSecondaryAction(
        app appIdentifier: String,
        elementIndex: Int,
        action: String
    ) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "performSecondaryAction") { _, _ in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            try SkyAXActions.performSecondaryAction(
                pid: app.processIdentifier,
                elementIndex: elementIndex,
                action: action
            )
        }
    }

    // MARK: - paste

    /// Paste content into the focused element, then restore the clipboard
    /// (spec: paste).
    public func paste(app appIdentifier: String, text: String, format: SkyPasteFormat = .text) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "paste") { [self] _, _ in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            try activateIfNeeded(app)
            let payload = try pasteboardWrapper.encode(text: text, format: format)
            let saved = try pasteboardWrapper.save()
            defer { pasteboardWrapper.restore(saved) }
            try pasteboardWrapper.write(payload)
            try SkyEventSynthesizer.pressKey("Control_L+v")
        }
    }

    // MARK: - Internals

    /// Policy gate wrapper (spec: withComputerUsePolicy).
    func gated<T>(
        appIdentifier: String,
        requestType: String,
        body: (_ target: SkyPolicyTarget, _ bundleID: String) async throws -> T
    ) async throws -> T {
        let policyTarget = try resolveForPolicy(appIdentifier)
        let result = policy.policy(for: policyTarget)
        if let error = SkyPolicyStore.error(for: result) {
            throw error
        }
        return try await body(policyTarget, policyTarget.bundleIdentifier)
    }

    func gatedVoid(
        appIdentifier: String,
        requestType: String,
        body: (_ target: SkyPolicyTarget, _ bundleID: String) async throws -> Void
    ) async throws {
        _ = try await gated(appIdentifier: appIdentifier, requestType: requestType, body: body)
    }

    /// Resolve the policy target from any identifier form.
    func resolveForPolicy(_ identifier: String) throws -> SkyPolicyTarget {
        let apps = listApps()
        // Direct bundle id hit (running or installed).
        if let hit = apps.first(where: { $0.bundleIdentifier?.lowercased() == identifier.lowercased() }) {
            return SkyPolicyTarget(
                appPath: hit.appPath ?? "",
                bundleIdentifier: hit.bundleIdentifier ?? identifier,
                displayName: hit.displayName ?? identifier,
                risk: policy.classify(bundleID: hit.bundleIdentifier ?? identifier),
                warningSubtitle: nil
            )
        }
        // Display-name / process-name hit among all apps (running first).
        let lowered = identifier.lowercased()
        let candidates = apps.filter {
            ($0.displayName?.lowercased() == lowered)
                || ($0.id.lowercased().hasSuffix(lowered))
        }
        if let only = candidates.first(where: { $0.isRunning }) ?? candidates.first, candidates.count >= 1 {
            return SkyPolicyTarget(
                appPath: only.appPath ?? "",
                bundleIdentifier: only.bundleIdentifier ?? only.id,
                displayName: only.displayName ?? identifier,
                risk: policy.classify(bundleID: only.bundleIdentifier ?? only.id),
                warningSubtitle: nil
            )
        }
        // Fall back to resolving as a running app (gets a synthetic bundle id).
        let app = try SkyAppResolver.resolveRunning(identifier)
        let bundleID = app.bundleIdentifier ?? app.localizedName ?? "pid:\(app.processIdentifier)"
        return SkyPolicyTarget(
            appPath: app.bundleURL?.path ?? "",
            bundleIdentifier: bundleID,
            displayName: app.localizedName ?? identifier,
            risk: policy.classify(bundleID: bundleID),
            warningSubtitle: nil
        )
    }

    /// Activate an app when it is not frontmost (window API convention).
    func activateIfNeeded(_ app: NSRunningApplication) throws {
        if !app.isActive {
            _ = try? app.activate(options: [.activateAllWindows])
            Thread.sleep(forTimeInterval: 0.08)
        }
    }

    func storeSnapshot(_ key: String, _ snapshot: SkyAXSnapshot) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        snapshots[key] = snapshot
    }

    func latestSnapshot(_ key: String) -> SkyAXSnapshot? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshots[key]
    }

    /// App-specific instructions registry (spec: appSpecificInstructions).
    /// Overridable; default ships guidance for common apps.
    func appSpecificInstructions(for bundleID: String) -> String? {
        switch bundleID.lowercased() {
        case "com.apple.textedit":
            return
                "TextEdit: focus a document window before typing. setValue replaces an entire text area; typeText inserts at the caret."
        case "com.apple.finder":
            return
                "Finder: navigation is list/column view; use performSecondaryAction AXOpen to open a selection."
        case "com.apple.iwork.numbers":
            return
                "Numbers: click once to select a cell (three to replace contents); values save immediately."
        default:
            return nil
        }
    }
}

extension SkyMouseButton {
    /// Convert to the synthesizer's button type.
    var type: SkyEventSynthesizer.SkyMouseButtonType {
        switch canonical {
        case .left, .l: return .left
        case .right, .r: return .right
        default: return .middle
        }
    }
}
