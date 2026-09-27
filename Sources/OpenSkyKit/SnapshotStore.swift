// OpenSky — SnapshotStore.swift
// Disk-backed AX snapshot store for cross-process state diffing.
// The reference runtime diffs within one long-lived process; OpenSky's CLI is
// process-per-call, so we persist the last snapshot per app to disk and reload
// it on the next invocation. MCP/plugin sessions get the same continuity.

import Foundation

public enum SkySnapshotStore {
    static var baseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("OpenSky/state", isDirectory: true)
    }

    struct StoredSnapshot: Codable {
        var appID: String
        var windowTitle: String?
        var windowFrameX: Double?, windowFrameY: Double?, windowFrameW: Double?, windowFrameH: Double?
        var nodes: [StoredNode]
        struct StoredNode: Codable {
            var elementIndex: Int
            var role: String
            var title: String?
            var value: String?
            var x: Double?, y: Double?, w: Double?, h: Double?
            var isEditable: Bool
            var actions: [String]
        }
    }

    static func fileURL(for appID: String) -> URL {
        // sanitize key
        let safe = appID.replacingOccurrences(of: "/", with: "_")
        return baseDir.appendingPathComponent("\(safe).json")
    }

    public static func loadPrevious(appID: String) -> SkyAXSnapshot? {
        let url = fileURL(for: appID)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredSnapshot.self, from: data) else { return nil }
        let nodes = stored.nodes.map { n in
            SkyAXNode(
                elementIndex: n.elementIndex,
                role: n.role,
                title: n.title,
                value: n.value,
                help: nil,
                frame: (n.x != nil && n.y != nil && n.w != nil && n.h != nil)
                    ? SkyAXFrame(x: n.x!, y: n.y!, width: n.w!, height: n.h!)
                    : nil,
                actions: n.actions,
                isEditable: n.isEditable,
                supportsTextSelection: false,
                childCount: 0
            )
        }
        let winFrame: SkyAXFrame?
        if let x = stored.windowFrameX, let y = stored.windowFrameY,
           let w = stored.windowFrameW, let h = stored.windowFrameH {
            winFrame = SkyAXFrame(x: x, y: y, width: w, height: h)
        } else {
            winFrame = nil
        }
        return SkyAXSnapshot(
            appID: stored.appID, pid: 0, windowTitle: stored.windowTitle, windowFrame: winFrame,
            nodes: nodes, text: "", capturedAt: Date()
        )
    }

    public static func persist(appID: String, snapshot: SkyAXSnapshot) {
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let stored = StoredSnapshot(
            appID: appID,
            windowTitle: snapshot.windowTitle,
            windowFrameX: snapshot.windowFrame?.x,
            windowFrameY: snapshot.windowFrame?.y,
            windowFrameW: snapshot.windowFrame?.width,
            windowFrameH: snapshot.windowFrame?.height,
            nodes: snapshot.nodes.map { n in
                .init(elementIndex: n.elementIndex, role: n.role, title: n.title, value: n.value,
                      x: n.frame?.x, y: n.frame?.y, w: n.frame?.width, h: n.frame?.height,
                      isEditable: n.isEditable, actions: n.actions)
            }
        )
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL(for: appID), options: .atomic)
        }
    }

    public static func clear(appID: String) {
        try? FileManager.default.removeItem(at: fileURL(for: appID))
    }
}
