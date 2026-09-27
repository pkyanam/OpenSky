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

    /// Reference-parity helper: resolve a running app, or transparently
    /// LAUNCH it when only installed (spec: "No need to open or launch apps;
    /// get_app_state transparently launches the app in the background").
    public static func resolveOrLaunch(_ identifier: String, settleSeconds: TimeInterval = 1.5) throws -> NSRunningApplication {
        if let running = try? resolveRunning(identifier) {
            return running
        }
        // Not running: find it in the installed list (LaunchServices) and launch.
        guard let bundleID = installedBundleID(for: identifier) else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.runningApplicationNotFound.rawValue,
                errorName: .runningApplicationNotFound,
                message: "No running or installed app matches '\(identifier)'",
                requestType: "resolveApp"
            )
        }
        let conf = NSWorkspace.OpenConfiguration()
        conf.activates = false   // background launch, like the reference
        let semaphore = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundleID), configuration: conf) { app, error in
            launched = app
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        guard let app = launched else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.runningApplicationNotFound.rawValue,
                errorName: .runningApplicationNotFound,
                message: "Installed match for '\(identifier)' (\(bundleID)) failed to launch",
                requestType: "resolveApp"
            )
        }
        Thread.sleep(forTimeInterval: settleSeconds)
        return app
    }

    /// Locate an installed app bundle path for an identifier (bundle id, name
    /// prefix, or .app name) via LaunchServices.
    static func installedBundleID(for identifier: String) -> String? {
        // bundle id direct: try to find an .app with this bundle id
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return url.path
        }
        // name: search /Applications + ~/Applications
        let lowered = identifier.lowercased()
        let candidates = identifier.hasSuffix(".app")
            ? [identifier]
            : ["\(identifier).app"]
        let searchDirs = ["/Applications", NSString(string: "~/Applications").expandingTildeInPath,
                          "/System/Applications"]
        for dir in searchDirs {
            for name in candidates {
                let path = (dir as NSString).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        // fuzzy: any .app whose name contains the identifier
        for dir in searchDirs {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                if let hit = entries.first(where: { $0.lowercased().contains(lowered) && $0.hasSuffix(".app") }) {
                    return (dir as NSString).appendingPathComponent(hit)
                }
            }
        }
        return nil
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
