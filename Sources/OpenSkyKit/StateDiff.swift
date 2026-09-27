// OpenSky — StateDiff.swift
// AX state diffing (parity with the reference implementation's default
// behavior): get_app_state returns a DIFF from the previous tree listing only
// removed, added, or changed elements. Token-efficient agent loops stay in
// context; disableDiff forces a fresh full tree.

import Foundation

public struct SkyStateDiff: Sendable {
    public let appID: String
    public let removed: [SkyAXNode]
    public let added: [SkyAXNode]
    public let changed: [(from: SkyAXNode, to: SkyAXNode)]

    /// Serialized diff text in the skyshot format.
    public var text: String {
        var lines: [String] = []
        lines.append("app=\(appID) diff from previous state — \(removed.count) removed, \(added.count) added, \(changed.count) changed")
        if !removed.isEmpty {
            lines.append("--- removed ---")
            lines.append(contentsOf: removed.map { "[\($0.elementIndex)] \($0.summary)" })
        }
        if !added.isEmpty {
            lines.append("--- added ---")
            lines.append(contentsOf: added.map { "[\($0.elementIndex)] \($0.summary)" })
        }
        if !changed.isEmpty {
            lines.append("--- changed ---")
            for (from, to) in changed {
                lines.append("[\(to.elementIndex)] \(to.summary)")
            }
        }
        if removed.isEmpty && added.isEmpty && changed.isEmpty {
            lines.append("(no changes since previous state)")
        }
        return lines.joined(separator: "\n")
    }
}

extension SkyAXNode {
    /// One-line summary without the [N] marker (used by the diff renderer).
    var summary: String {
        var parts: [String] = [role]
        if let title, !title.isEmpty { parts.append("title=\(title)") }
        if let value, !value.isEmpty { parts.append("value=\(value)") }
        if let frame {
            parts.append(String(format: "frame=(%.0f,%.0f,%.0fx%.0f)", frame.x, frame.y, frame.width, frame.height))
        }
        if isEditable { parts.append("editable") }
        if !actions.isEmpty { parts.append("actions=(\(actions.joined(separator: ",")))") }
        return parts.joined(separator: " ")
    }
}

public enum SkyStateDiffer {
    /// Diff old → new. Identity heuristic: same elementIndex AND (role changed OR
    /// title/value/frame changed) = changed; index present in old but missing in
    /// new = removed; new index not in old = added.
    public static func diff(old: SkyAXSnapshot, new: SkyAXSnapshot) -> SkyStateDiff {
        let oldByID = Dictionary(old.nodes.map { ($0.elementIndex, $0) }, uniquingKeysWith: { a, _ in a })
        let newByID = Dictionary(new.nodes.map { ($0.elementIndex, $0) }, uniquingKeysWith: { a, _ in a })

        var removed: [SkyAXNode] = []
        var changed: [(SkyAXNode, SkyAXNode)] = []
        for (idx, oldNode) in oldByID {
            guard let newNode = newByID[idx] else {
                removed.append(oldNode)
                continue
            }
            if !isEquivalent(oldNode, newNode) {
                changed.append((oldNode, newNode))
            }
        }
        var added: [SkyAXNode] = []
        for (idx, newNode) in newByID where oldByID[idx] == nil {
            added.append(newNode)
        }
        return SkyStateDiff(appID: new.appID, removed: removed, added: added, changed: changed)
    }

    static func isEquivalent(_ a: SkyAXNode, _ b: SkyAXNode) -> Bool {
        a.role == b.role
            && a.title == b.title
            && a.value == b.value
            && a.frame == b.frame
            && a.isEditable == b.isEditable
            && a.actions == b.actions
    }
}
