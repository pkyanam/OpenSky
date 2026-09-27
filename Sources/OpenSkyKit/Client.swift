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
    /// Last mutating-action timestamp per app — drives reference-parity
    /// auto-wait (state capture settles before returning).
    private var lastActionAt: [String: Date] = [:]
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
            // Parity: transparently launches installed-but-not-running apps.
            let app = try SkyAppResolver.resolveOrLaunch(appOrArgs)
            // Reference-parity auto-wait: after a recent mutating action,
            // wait for the UI to settle before capturing (1s dwell + up to
            // 5s stability poll). First-ever state returns immediately.
            await settleAfterAction(bundleID) { [app] in Int(app.processIdentifier) }
            let snapshot = try SkyAXWalker.captureApp(pid: Int(app.processIdentifier), appID: bundleID)

            // Token-efficiency parity: when a previous snapshot exists and
            // diffing is enabled, deliver a diff instead of the full tree.
            // Source of previous = in-memory (same process) OR the disk store
            // (cross-process: CLI/MCP invocations keep diffing across calls).
            let previous = disableDiff ? nil : (latestSnapshot(bundleID) ?? SkySnapshotStore.loadPrevious(appID: bundleID))
            storeSnapshot(bundleID, snapshot)
            SkySnapshotStore.persist(appID: bundleID, snapshot: snapshot)

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

            let stateText: String
            if let previous, previous.nodes.count > 0 {
                let diff = SkyStateDiffer.diff(old: previous, new: snapshot)
                stateText = diff.text
            } else {
                stateText = snapshot.text
            }
            let skyshot = SkyWindowSkyshot(text: stateText, screenshot: shot)
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
                    do {
                        try SkyAXActions.performSecondaryAction(
                            pid: pid_t(pid),
                            elementIndex: elementIndex,
                            action: "AXPress"
                        )
                        return
                    } catch {
                        // Reference-parity resilience: live AX handles churn
                        // (re-created web content, reparented rows). If the
                        // action no longer resolves, fall through to the
                        // snapshot-frame coordinate click below.
                    }
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
                // Reference parity: targeted mouse input does NOT activate the app.
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
                // Reference parity: targeted mouse input does NOT activate the app.
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
            // Reference parity: targeted mouse input does NOT activate the app.
            try SkyEventSynthesizer.drag(
                from: CGPoint(x: winFrame.x + fromX, y: winFrame.y + fromY),
                to: CGPoint(x: winFrame.x + toX, y: winFrame.y + toY)
            )
        }
    }

    // MARK: - pressKey

    /// Press a key chord into the app (spec: pressKey).
    /// Keys are delivered via CGEventPostToPid when the app supports it —
    /// background apps receive keyboard without stealing focus.
    public func pressKey(app appIdentifier: String, key: String) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "pressKey") { [self] _, _ in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            // Keyboard on macOS requires a key window. Reference parity:
            // activate ONLY when the app is not already active; mouse paths
            // never activate.
            if !app.isActive { try activateIfNeeded(app) }
            try SkyEventSynthesizer.pressKey(key)
        }
    }

    // MARK: - typeText

    /// Type text into the app's focused element (spec: typeText).
    /// Background-targeted: CGEventPostToPid when the app is unfocused.
    public func typeText(app appIdentifier: String, text: String) async throws {
        try await gatedVoid(appIdentifier: appIdentifier, requestType: "typeText") { [self] _, _ in
            let app = try SkyAppResolver.resolveRunning(appIdentifier)
            if !app.isActive { try activateIfNeeded(app) }
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
            // Reference parity: targeted mouse input does NOT activate the app.

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
            let payload = try pasteboardWrapper.encode(text: text, format: format)
            let saved = try pasteboardWrapper.save()
            defer { pasteboardWrapper.restore(saved) }
            try pasteboardWrapper.write(payload)
            if !app.isActive { try activateIfNeeded(app) }
            try SkyEventSynthesizer.pressKey("Control_L+v")
        }
    }

    // MARK: - Internals

    /// Policy gate wrapper (spec: withComputerUsePolicy).
    /// Also the lock-screen gate (docs/LOCK-SCREEN.md): while the session is
    /// locked, mutating actions queue by default (`whenLocked` client option:
    /// queue | fail | skip) and auto-resume on unlock. Read-only calls
    /// (getAppState/listApps/policy) bypass this gate on purpose — they are
    /// safe while parked and let agents observe state across a lock.
    func gated<T>(
        appIdentifier: String,
        requestType: String,
        body: (_ target: SkyPolicyTarget, _ bundleID: String) async throws -> T
    ) async throws -> T {
        switch await LockInputGate.shared.gate(whenLockedMode) {
        case .proceed, .proceedAfterQueue:
            break
        case .failedLocked:
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.screenLocked.rawValue,
                errorName: .screenLocked,
                message: "Session is locked. Use --when-locked queue (default) to auto-resume after unlock, or fail/skip.",
                requestType: requestType
            )
        case .skippedLocked:
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.skippedLocked.rawValue,
                errorName: .skippedLocked,
                message: "Action skipped because the session is locked (whenLocked=skip).",
                requestType: requestType
            )
        }
        let policyTarget = try resolveForPolicy(appIdentifier)
        let result = policy.policy(for: policyTarget)
        if let error = SkyPolicyStore.error(for: result) {
            throw error
        }
        return try await body(policyTarget, policyTarget.bundleIdentifier)
    }

    /// Lock-screen behavior for mutating actions (default: queue until unlock).
    public var whenLockedMode: LockInputGate.Mode = .queue

    func gatedVoid(
        appIdentifier: String,
        requestType: String,
        body: (_ target: SkyPolicyTarget, _ bundleID: String) async throws -> Void
    ) async throws {
        _ = try await gated(appIdentifier: appIdentifier, requestType: requestType, body: body)
        // Mutating action completed — record for the settle-on-next-state wait.
        if let target = try? resolveForPolicy(appIdentifier) {
            noteAction(target.bundleIdentifier)
        }
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
            // Wait until the app really IS active (max ~1s): keystrokes sent
            // mid app-switch land in the previously-frontmost app.
            for _ in 0..<20 {
                if app.isActive { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
    }

    func storeSnapshot(_ key: String, _ snapshot: SkyAXSnapshot) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        snapshots[key] = snapshot
    }

    func latestSnapshot(_ key: String) -> SkyAXSnapshot? {
        snapshotLock.lock()
        let mem = snapshots[key]
        snapshotLock.unlock()
        // Cross-process parity: CLI/MCP runs are process-per-call, so element
        // indices from a previous invocation must still resolve. Fall back to
        // the disk store (populated by the last getState anywhere).
        return mem ?? SkySnapshotStore.loadPrevious(appID: key)
    }

    /// Record that a mutating action just ran against `key` (reference-parity:
    /// the runtime then waits ~1s, +up to 5s while loading indicators churn,
    /// before the next state capture returns settled state).
    func noteAction(_ key: String) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        lastActionAt[key] = Date()
    }

    /// Wait until the app's UI settles after a recent action (max 6s total).
    /// Heuristic: require the minimum dwell (1s), then poll the AX tree until
    /// two consecutive captures agree (or the +5s loading window elapses).
    func settleAfterAction(_ key: String, pid pidProvider: @escaping () -> Int?) async {
        let (at, hasAction) = {
            snapshotLock.lock(); defer { snapshotLock.unlock() }
            return (lastActionAt[key] ?? .distantPast, lastActionAt[key] != nil)
        }()
        guard hasAction else { return }
        let elapsed = Date().timeIntervalSince(at)
        let minDwell: TimeInterval = 1.0
        if elapsed < minDwell {
            try? await Task.sleep(nanoseconds: UInt64((minDwell - elapsed) * 1_000_000_000))
        }
        // Stability poll: up to 5 extra seconds while the tree keeps changing.
        let deadline = Date().addingTimeInterval(5.0)
        var lastCount = -1
        while Date() < deadline {
            guard let pid = pidProvider() else { return }
            guard let probe = try? SkyAXWalker.captureApp(pid: pid, appID: key) else { return }
            let count = probe.nodes.count
            if count == lastCount, count > 0 { return }  // settled
            lastCount = count
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        // give up waiting — return current (best-effort) state
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
