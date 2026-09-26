import AppKit
import Foundation

/// Resolves an app identifier string (bundle id, display name, process name,
/// path, or PID) against NSWorkspace, and enumerates running + installable apps.
public enum SkyAppResolver {
    /// All apps worth targeting: running GUI apps first, then /Applications.
    public static func listApps() -> [SkyDiscoveredApp] {
        var out: [SkyDiscoveredApp] = []
        var seen = Set<String>()

        let ws = NSWorkspace.shared
        let running = ws.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        // Track frontmost pid.
        let frontPID = running.first(where: { $0.isActive })?.processIdentifier

        for app in running.sorted(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) {
            let bundleID = app.bundleIdentifier
            let name = displayName(of: app)
            let id = bundleID ?? name ?? "pid:\(app.processIdentifier)"
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)

            let lastUsed = app.launchDate?.iso8601
            out.append(
                SkyDiscoveredApp(
                    id: id,
                    bundleIdentifier: bundleID,
                    displayName: name,
                    appPath: app.bundleURL?.path,
                    pid: Int(app.processIdentifier),
                    isRunning: true,
                    isFrontmost: app.processIdentifier == frontPID,
                    lastUsedDate: lastUsed,
                    useCount: nil
                )
            )
        }

        // Also surface installed-but-not-running apps from /Applications so
        // startApp-like flows can target them.
        let appsDir = ("/Applications" as NSString)
        if let children = try? FileManager.default.contentsOfDirectory(
            atPath: appsDir as String
        ) {
            for child in children where child.hasSuffix(".app") {
                let path = appsDir.appendingPathComponent(child)
                guard let bundle = Bundle(url: URL(fileURLWithPath: path)),
                      let bundleID = bundle.bundleIdentifier,
                      !seen.contains(bundleID)
                else { continue }
                seen.insert(bundleID)
                let name = (child as NSString).deletingPathExtension
                let localName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                out.append(
                    SkyDiscoveredApp(
                        id: bundleID,
                        bundleIdentifier: bundleID,
                        displayName: localName ?? name,
                        appPath: path,
                        pid: nil,
                        isRunning: false,
                        isFrontmost: false,
                        lastUsedDate: nil,
                        useCount: nil
                    )
                )
            }
        }
        return out
    }

    /// Resolve an identifier to a running NSRunningApplication.
    public static func resolveRunning(_ identifier: String) throws -> NSRunningApplication {
        let apps = NSWorkspace.shared.runningApplications
        let regular = apps.filter { $0.activationPolicy == .regular }

        if let pid = Int(identifier) {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)),
               app.activationPolicy == .regular {
                return app
            }
        }
        if identifier.hasPrefix("pid:") {
            let pidPart = identifier.dropFirst(4)
            if let pid = Int(pidPart),
               let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                return app
            }
        }
        // Exact bundle id match first.
        let byBundle = regular.filter { $0.bundleIdentifier == identifier }
        if byBundle.count == 1 { return byBundle[0] }
        if byBundle.count > 1 {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.ambiguousApp.rawValue,
                errorName: .ambiguousApp,
                message: "Multiple running apps match bundle id '\(identifier)'",
                requestType: "resolveApp"
            )
        }
        // Display name / process name match (case-insensitive), exact then prefix.
        let lowered = identifier.lowercased()
        let byName = regular.filter {
            (displayName(of: $0)?.lowercased() == lowered)
                || ($0.localizedName?.lowercased() == lowered)
                || (executableName(of: $0)?.lowercased() == lowered)
        }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 {
            let names = byName.compactMap { $0.localizedName }.joined(separator: ", ")
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.ambiguousApp.rawValue,
                errorName: .ambiguousApp,
                message: "Multiple running apps match '\(identifier)': \(names)",
                requestType: "resolveApp"
            )
        }
        // Prefix fallback on name.
        let byPrefix = regular.filter {
            ($0.localizedName?.lowercased().hasPrefix(lowered) ?? false)
                || (executableName(of: $0)?.lowercased().hasPrefix(lowered) ?? false)
        }
        if byPrefix.count == 1 { return byPrefix[0] }

        throw SkyComputerUseError(
            code: SkyComputerUseErrorCode.runningApplicationNotFound.rawValue,
            errorName: .runningApplicationNotFound,
            message: "No running app matches '\(identifier)'",
            requestType: "resolveApp"
        )
    }

    static func displayName(of app: NSRunningApplication) -> String? {
        if let n = app.localizedName, !n.isEmpty { return n }
        if let url = app.bundleURL {
            return (url.lastPathComponent as NSString).deletingPathExtension
        }
        return executableName(of: app)
    }

    static func executableName(of app: NSRunningApplication) -> String? {
        guard let url = app.executableURL else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }
}

extension Date {
    var iso8601: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: self)
    }
}
