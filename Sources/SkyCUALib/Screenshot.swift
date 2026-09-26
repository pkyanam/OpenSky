import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import ImageIO

/// Window screenshot capture via ScreenCaptureKit (public API, macOS 14.0+).
/// SCScreenshotManager single-shot capture requires macOS 14+; on older hosts
/// the client falls back to CGWindowListCreateImage.
@available(macOS 14.0, *)
public enum SkyScreenshotCapture {

    /// Capture the window owned by `pid` (topmost on-screen window) as PNG.
    /// Returns (fileURL, dataURL, width, height).
    public static func captureWindowPNG(
        pid: Int,
        outputDirectory: URL? = nil
    ) async throws -> (fileURL: URL, dataURL: String, width: Int, height: Int) {
        let windowID = try await mainWindowID(forPID: pid)
        return try await captureWindowPNG(
            windowID: windowID,
            outputDirectory: outputDirectory
        )
    }

    /// Capture a specific CGWindowID as PNG (window must be on-screen).
    public static func captureWindowPNG(
        windowID: CGWindowID,
        outputDirectory: URL? = nil
    ) async throws -> (fileURL: URL, dataURL: String, width: Int, height: Int) {
        // Resolve the SCWindow for the CGWindowID via one shareable content scan.
        let shareable = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let scWindow = shareable.windows.first(where: { $0.windowID == windowID }) else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.accessibilityError.rawValue,
                errorName: .accessibilityError,
                message: "Window \(windowID) not found among capturable on-screen windows.",
                requestType: "screenshot"
            )
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        return try await capture(
            filter: filter,
            outputDirectory: outputDirectory,
            sourceBounds: CGRect(
                x: scWindow.frame.origin.x,
                y: scWindow.frame.origin.y,
                width: scWindow.frame.width,
                height: scWindow.frame.height
            )
        )
    }

    /// Capture the full main display.
    public static func captureDisplayPNG(
        outputDirectory: URL? = nil
    ) async throws -> (fileURL: URL, dataURL: String, width: Int, height: Int) {
        let shareable = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = shareable.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? shareable.displays.first
        else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.accessibilityError.rawValue,
                errorName: .accessibilityError,
                message: "No display available for capture.",
                requestType: "screenshot"
            )
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await capture(
            filter: filter,
            outputDirectory: outputDirectory,
            sourceBounds: CGRect(
                x: display.frame.origin.x,
                y: display.frame.origin.y,
                width: display.frame.width,
                height: display.frame.height
            )
        )
    }

    // MARK: - Core

    static func capture(
        filter: SCContentFilter,
        outputDirectory: URL?,
        sourceBounds: CGRect
    ) async throws -> (fileURL: URL, dataURL: String, width: Int, height: Int) {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = true

        // Size the capture to the source bounds (pixels, 2x on Retina).
        let scale = max(1, Int(NSScreen.main.map { $0.backingScaleFactor } ?? 1))
        config.width = max(1, Int(sourceBounds.width) * scale)
        config.height = max(1, Int(sourceBounds.height) * scale)

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return try writePNG(cgImage: image, outputDirectory: outputDirectory)
    }

    static func writePNG(
        cgImage: CGImage,
        outputDirectory: URL?
    ) throws -> (fileURL: URL, dataURL: String, width: Int, height: Int) {
        let dir = outputDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("skyshot-\(UUID().uuidString).png")

        guard let dest = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.internalError.rawValue,
                errorName: .internalError,
                message: "Cannot create PNG destination at \(fileURL.path).",
                requestType: "screenshot"
            )
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.internalError.rawValue,
                errorName: .internalError,
                message: "PNG encode failed.",
                requestType: "screenshot"
            )
        }
        let data = try Data(contentsOf: fileURL)
        let dataURL = "data:image/png;base64,\(data.base64EncodedString())"
        return (fileURL, dataURL, cgImage.width, cgImage.height)
    }

    // MARK: - Window lookup

    /// Find on-screen layer-0 windows owned by a pid (topmost first), ≥32pt.
    public static func windows(forPID pid: Int) -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        var ids: [CGWindowID] = []
        for entry in info {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == pid,
                  let id = entry[kCGWindowNumber as String] as? Int
            else { continue }
            let bounds = entry[kCGWindowBounds as String] as? [String: Any]
            let w = (bounds?["Width"] as? NSNumber)?.intValue ?? 0
            let h = (bounds?["Height"] as? NSNumber)?.intValue ?? 0
            guard w >= 32 && h >= 32 else { continue }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            ids.append(CGWindowID(id))
        }
        return ids
    }

    public static func mainWindowID(forPID pid: Int) async throws -> CGWindowID {
        let ids = windows(forPID: pid)
        guard let first = ids.first else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.accessibilityError.rawValue,
                errorName: .accessibilityError,
                message: "No on-screen window for pid \(pid).",
                requestType: "screenshot"
            )
        }
        return first
    }

    /// Availability probe: true when any display is shareable (screen
    /// recording permission granted).
    public static func screenRecordingAvailable() async -> Bool {
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            return !shareable.displays.isEmpty
        } catch {
            return false
        }
    }
}
