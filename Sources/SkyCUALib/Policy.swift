import Foundation

/// Risk classification for an app target (spec: MacAppPolicyTarget.risk).
public enum SkyPolicyRisk: String, Sendable {
    case low
    case high
}

/// Decision outcome (spec: MacAppPolicyResult.decision).
public enum SkyPolicyDecision: String, Sendable {
    case allowed
    case denied
    case forbidden
}

/// Target description attached to a policy result
/// (spec: MacAppPolicyTarget).
public struct SkyPolicyTarget: Sendable, Equatable {
    public let appPath: String
    public let bundleIdentifier: String
    public let displayName: String
    public let risk: SkyPolicyRisk
    public let warningSubtitle: String?

    public init(
        appPath: String,
        bundleIdentifier: String,
        displayName: String,
        risk: SkyPolicyRisk,
        warningSubtitle: String? = nil
    ) {
        self.appPath = appPath
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.risk = risk
        self.warningSubtitle = warningSubtitle
    }
}

/// Full policy result (spec: MacAppPolicyResult).
public struct SkyAppPolicyResult: Sendable, Equatable {
    /// Whether the UI may offer "always allow" persistence.
    public let allowPersistentApproval: Bool
    public let decision: SkyPolicyDecision
    public let target: SkyPolicyTarget

    public init(
        allowPersistentApproval: Bool,
        decision: SkyPolicyDecision,
        target: SkyPolicyTarget
    ) {
        self.allowPersistentApproval = allowPersistentApproval
        self.decision = decision
        self.target = target
    }
}

/// Per-app approval store backed by UserDefaults (public API).
///
/// Semantics (modeled on the spec's policy behavior):
/// - `denied` (org-level block list): action refused with a "blocked by
///   your organization's policy" error.
/// - `forbidden` (safety block list, e.g. system-critical apps): refused
///   with a "not allowed for safety reasons" error.
/// - `allowed` (session or persistent grant): action proceeds.
/// - default: LOW risk -> allowed immediately; HIGH risk -> denied pending
///   an explicit approval (default deny-high-risk).
public final class SkyPolicyStore: @unchecked Sendable {
    /// Locked shared instance; UserDefaults access is serialized internally.
    public static let shared: SkyPolicyStore = SkyPolicyStore()
    private static let lock = NSLock()

    private let defaults: UserDefaults
    private let suiteKeyPrefix = "SkyCUA.policy."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Classification

    /// Apps that must never be automated (session-critical / destructive).
    static let forbiddenBundleIDs: Set<String> = [
        "com.apple.finder",           // system shell
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.systempreferences", // System Settings can change security state
        "com.apple.ShootMe",           // screenshot/screencapture helpers
        "com.apple.screencaptureui",
        "com.apple.SecurityAgent",
        "com.apple.SessionManager",
        "com.apple.keychainaccess",
        "com.apple.ActivityMonitor",
    ]

    /// Apps considered high-risk by default (can spend money, delete data,
    /// reach the network interactively).
    static let highRiskBundleIDs: Set<String> = [
        "com.apple.mail",
        "com.apple.MobileSMS",
        "com.apple.iChat",           // Messages (newer ids)
        "com.appleFaceTime",         // FaceTime (call initiating)
        "com.apple.facetime",
        "com.apple.AppStore",
        "com.apple.wallet",
        "com.apple.systempreferences",
    ]

    public func classify(bundleID: String) -> SkyPolicyRisk {
        let lowered = bundleID.lowercased()
        if Self.highRiskBundleIDs.contains(lowered) { return .high }
        // Bundles under ~/Applications or unsigned helper apps: low.
        return .low
    }

    // MARK: - Decision

    public func policy(for target: SkyPolicyTarget) -> SkyAppPolicyResult {
        let bundleID = target.bundleIdentifier.lowercased()

        if Self.forbiddenBundleIDs.contains(bundleID) {
            return SkyAppPolicyResult(
                allowPersistentApproval: false,
                decision: .forbidden,
                target: target
            )
        }
        if deniedList.contains(bundleID) {
            return SkyAppPolicyResult(
                allowPersistentApproval: false,
                decision: .denied,
                target: target
            )
        }
        if approvedList.contains(bundleID) {
            return SkyAppPolicyResult(
                allowPersistentApproval: target.risk == .high,
                decision: .allowed,
                target: target
            )
        }
        switch target.risk {
        case .low:
            return SkyAppPolicyResult(
                allowPersistentApproval: true,
                decision: .allowed,
                target: target
            )
        case .high:
            // Default deny-high-risk: no stored grant -> denied pending approval.
            return SkyAppPolicyResult(
                allowPersistentApproval: true,
                decision: .denied,
                target: target
            )
        }
    }

    // MARK: - Persistence

    var approvedList: Set<String> {
        get {
            Set(defaults.stringArray(forKey: key("approved")) ?? [])
        }
        set {
            defaults.set(Array(newValue).sorted(), forKey: key("approved"))
        }
    }

    var deniedList: Set<String> {
        get {
            Set(defaults.stringArray(forKey: key("denied")) ?? [])
        }
        set {
            defaults.set(Array(newValue).sorted(), forKey: key("denied"))
        }
    }

    /// Record an interactive approval. `persistent: true` survives sessions.
    public func approve(bundleID: String, persistent: Bool) {
        let key = bundleID.lowercased()
        var approved = approvedList
        approved.insert(key)
        approvedList = approved
        if persistent {
            var denied = deniedList
            denied.remove(key)
            deniedList = denied
        }
    }

    /// Revoke an approval (e.g. from settings).
    public func revoke(bundleID: String) {
        let key = bundleID.lowercased()
        var approved = approvedList
        approved.remove(key)
        approvedList = approved
    }

    /// Explicitly deny an app (org-style block).
    public func deny(bundleID: String) {
        let key = bundleID.lowercased()
        var denied = deniedList
        denied.insert(key)
        deniedList = denied
        var approved = approvedList
        approved.remove(key)
        approvedList = approved
    }

    private func key(_ suffix: String) -> String {
        suiteKeyPrefix + suffix
    }
}

// MARK: - Error mapping

extension SkyPolicyStore {
    /// Throw the spec-shaped error for a denied/forbidden decision.
    public static func error(for result: SkyAppPolicyResult) -> SkyComputerUseError? {
        switch result.decision {
        case .allowed:
            return nil
        case .denied:
            return SkyComputerUseError(
                code: SkyComputerUseErrorCode.appNotAllowed.rawValue,
                errorName: .appNotAllowed,
                message: "SkyCUA is blocked from using the app '\(result.target.bundleIdentifier)' by policy.",
                requestType: "getAppPolicy"
            )
        case .forbidden:
            return SkyComputerUseError(
                code: SkyComputerUseErrorCode.appNotAllowed.rawValue,
                errorName: .policyForbidden,
                message: "SkyCUA is not allowed to use the app '\(result.target.bundleIdentifier)' for safety reasons.",
                requestType: "getAppPolicy"
            )
        }
    }
}
