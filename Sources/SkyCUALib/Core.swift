// SkyCUA — clean-room macOS computer-use framework.
//
// Interface shapes modeled on the ChatGPT.app "Computer Use" TypeScript API
// (client.d.ts / sky-window-api.md used as INTERFACE SPEC ONLY, per clean-room
// rules). All implementation is on public macOS frameworks:
// AppKit/NSWorkspace, Accessibility (AXUIElement), CoreGraphics (CGEvent),
// ScreenCaptureKit, Foundation (UserDefaults).

// Canonical public entry point: mirrors `MacComputerUseClient`; defined in
// Client.swift as `SkyMacComputerUseClient`.

// MARK: - App discovery

/// One entry from `listApps()` (spec: SkyDiscoveredApp / ListAppsApp).
public struct SkyDiscoveredApp: Sendable, Equatable {
    /// Canonical app id to pass as `app` when targeting a window.
    public let id: String
    public let bundleIdentifier: String?
    public let displayName: String?
    /// Absolute path of the app bundle on disk.
    public let appPath: String?
    public let pid: Int?
    public let isRunning: Bool
    public let isFrontmost: Bool
    /// ISO 8601 timestamp for recent app usage, when available.
    public let lastUsedDate: String?
    /// Usage-count signal, when available.
    public let useCount: Int?

    public init(
        id: String,
        bundleIdentifier: String? = nil,
        displayName: String? = nil,
        appPath: String? = nil,
        pid: Int? = nil,
        isRunning: Bool,
        isFrontmost: Bool = false,
        lastUsedDate: String? = nil,
        useCount: Int? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.appPath = appPath
        self.pid = pid
        self.isRunning = isRunning
        self.isFrontmost = isFrontmost
        self.lastUsedDate = lastUsedDate
        self.useCount = useCount
    }
}

// MARK: - State / skyshot

/// Screenshot handle (spec: MacWindowSkyshot.screenshot / Screenshot).
public struct SkyScreenshot: Sendable, Equatable {
    /// Data URL (data:image/png;base64,...) or a file:// URL for a captured file.
    public let url: String
    public let mimeType: String?

    public init(url: String, mimeType: String? = "image/png") {
        self.url = url
        self.mimeType = mimeType
    }
}

/// The "skyshot": accessibility text plus screenshot (spec: MacWindowSkyshot).
public struct SkyWindowSkyshot: Sendable, Equatable {
    /// Serialized accessibility text with element indices.
    public let text: String
    public let screenshot: SkyScreenshot?

    public init(text: String, screenshot: SkyScreenshot? = nil) {
        self.text = text
        self.screenshot = screenshot
    }
}

/// Result of `getAppState` / `startApp` (spec: MacWindowAppState / AppState).
public struct SkyWindowAppState: Sendable {
    /// App identifier for the captured window (canonical id).
    public let app: String
    /// App-specific instructions, delivered on first access when configured.
    public let appSpecificInstructions: String?
    public let skyshot: SkyWindowSkyshot?

    public init(app: String, appSpecificInstructions: String? = nil, skyshot: SkyWindowSkyshot? = nil) {
        self.app = app
        self.appSpecificInstructions = appSpecificInstructions
        self.skyshot = skyshot
    }
}

// MARK: - Errors

/// Error names surfaced through `SkyComputerUseError`.
public enum SkyComputerUseErrorName: String, Sendable {
    case appNotAllowed
    case runningApplicationNotFound
    case accessibilityError
    case permissionsNotGranted
    case permissionsPending
    case invalidApp
    case ambiguousApp
    case screenLocked
    case policyDenied
    case policyForbidden
    case unsupportedAction
    case elementNotFound
    case internalError
}

/// Numeric codes mirror the spec's `ServerErrorCode` subset where it exists;
/// internalError is our own (not in the spec's list).
public enum SkyComputerUseErrorCode: Int, Sendable {
    case appNotAllowed = -10006
    case runningApplicationNotFound = -10007
    case accessibilityError = -10008
    case permissionsNotGranted = -10009
    case invalidApp = -10010
    case ambiguousApp = -10018
    case screenLocked = -10020
    case internalError = -10095
    case noCode = 0
}

/// Primary error type (spec: SkyComputerUseError).
public struct SkyComputerUseError: Error, Sendable, CustomStringConvertible {
    public let code: Int
    public let errorName: SkyComputerUseErrorName
    public let message: String
    public let requestType: String

    public init(code: Int, errorName: SkyComputerUseErrorName, message: String, requestType: String) {
        self.code = code
        self.errorName = errorName
        self.message = message
        self.requestType = requestType
    }

    public static func from(
        _ errorName: SkyComputerUseErrorName,
        code: SkyComputerUseErrorCode? = nil,
        message: String,
        requestType: String
    ) -> SkyComputerUseError {
        SkyComputerUseError(
            code: code?.rawValue ?? 0,
            errorName: errorName,
            message: message,
            requestType: requestType
        )
    }

    public var description: String {
        "\(requestType): \(errorName.rawValue) (\(code)): \(message)"
    }
}

// MARK: - Input argument shapes (spec-parity names)

public enum SkyMouseButton: String, Sendable {
    case left, right, middle
    case l = "l"
    case r = "r"
    case m = "m"

    /// Canonical button, resolving l/r/m aliases.
    public var canonical: SkyMouseButton {
        switch self {
        case .l: return .left
        case .r: return .right
        case .m: return .middle
        default: return self
        }
    }
}

public enum SkyDirection: String, Sendable {
    case up, down, left, right
    case u = "u"
    case d = "d"
    case l = "l"
    case r = "r"

    /// Canonical direction, resolving u/d/l/r aliases.
    public var canonical: SkyDirection {
        switch self {
        case .u: return .up
        case .d: return .down
        case .l: return .left
        case .r: return .right
        default: return self
        }
    }
}

public enum SkyPasteFormat: String, Sendable {
    case text
    case md
    case html
}

public enum SkySelectionType: String, Sendable {
    case text
    case cursorBefore = "cursor_before"
    case cursorAfter = "cursor_after"
}
