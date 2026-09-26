import ApplicationServices
import Foundation

/// One node of the serialized accessibility tree, carrying the index the
/// client will reference in click/setValue/etc.
public struct SkyAXNode: Sendable {
    /// Depth-first element index assigned during the walk (stable per snapshot).
    public let elementIndex: Int
    public let role: String
    public let title: String?
    public let value: String?
    public let help: String?
    /// Window-relative frame, when known.
    public let frame: SkyAXFrame?
    /// AX action names supported by this element.
    public let actions: [String]
    /// Editable per AXEditableValue protocol or text-selection support.
    public let isEditable: Bool
    /// Element supports being selected (AXSelectedTextRange settable).
    public let supportsTextSelection: Bool
    public let childCount: Int

    public init(
        elementIndex: Int,
        role: String,
        title: String? = nil,
        value: String? = nil,
        help: String? = nil,
        frame: SkyAXFrame? = nil,
        actions: [String] = [],
        isEditable: Bool = false,
        supportsTextSelection: Bool = false,
        childCount: Int = 0
    ) {
        self.elementIndex = elementIndex
        self.role = role
        self.title = title
        self.value = value
        self.help = help
        self.frame = frame
        self.actions = actions
        self.isEditable = isEditable
        self.supportsTextSelection = supportsTextSelection
        self.childCount = childCount
    }
}

/// Window-relative rectangle in points.
public struct SkyAXFrame: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Result of an AX walk: flat indexed node list plus serialized text.
public struct SkyAXSnapshot: Sendable {
    public let appID: String
    public let pid: Int
    public let windowTitle: String?
    public let windowFrame: SkyAXFrame?
    public let nodes: [SkyAXNode]
    /// Condensed text with [index] markers — the "text" half of a skyshot.
    public let text: String
    /// Creation date for cache invalidation.
    public let capturedAt: Date

    /// Lookup by element index (nil when out of range).
    public func node(at index: Int) -> SkyAXNode? {
        guard index >= 0 && index < nodes.count else { return nil }
        return nodes[index]
    }
}

/// Depth-first AXUIElement walker producing stable per-snapshot indices.
///
/// Indexing contract: nodes are numbered depth-first in child order starting
/// at 0 for the root window element. A snapshot is immutable once produced;
/// every action against the app references indices from the LATEST snapshot.
public enum SkyAXWalker {

    /// Attribute names used during the walk (public macOS AX attributes).
    static let roleAttr = kAXRoleAttribute as String
    static let titleAttr = kAXTitleAttribute as String
    static let valueAttr = kAXValueAttribute as String
    static let helpAttr = kAXHelpAttribute as String
    static let focusedAttr = kAXFocusedAttribute as String
    static let positionAttr = kAXPositionAttribute as String
    static let sizeAttr = kAXSizeAttribute as String
    static let childrenAttr = kAXChildrenAttribute as String
    static let windowAttr = kAXWindowAttribute as String
    static let windowsAttr = kAXWindowsAttribute as String
    static let mainWindowAttr = kAXMainWindowAttribute as String
    static let focusedWindowAttr = kAXFocusedWindowAttribute as String
    static let titleUIElementAttr = kAXTitleUIElementAttribute as String
    static let placeholderAttr = kAXPlaceholderValueAttribute as String
    static let selectedTextRangeAttr = kAXSelectedTextRangeAttribute as String
    static let selectedAttr = kAXSelectedAttribute as String
    static let minValueAttr = kAXMinValueAttribute as String
    static let maxValueAttr = kAXMaxValueAttribute as String

    static let maxDepth = 40
    static let maxNodes = 12000

    /// Capture the main/focused window of a running app as an indexed snapshot.
    public static func captureApp(pid: Int, appID: String) throws -> SkyAXSnapshot {
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        // Pick focused window, else main window, else first window.
        var window: AXUIElement?
        if let w = try? fetchWindow(appElement, focusedWindowAttr) ?? fetchWindow(appElement, mainWindowAttr) {
            window = w
        }
        if window == nil {
            if let list = try? arrayValue(appElement, windowsAttr) {
                let swiftList = list as [AnyObject]
                if let first = swiftList.first {
                    window = first as! AXUIElement
                }
            }
        }
        guard let targetWindow = window else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.accessibilityError.rawValue,
                errorName: .accessibilityError,
                message: "No accessible window for pid \(pid) (\(appID)). Is the app running with a window?",
                requestType: "getAppState"
            )
        }
        let windowTitle = try? stringValue(targetWindow, kAXTitleAttribute as String) ?? nil
        let windowFrame = try? frameValue(targetWindow)
        var nodes: [SkyAXNode] = []
        var counter = 0
        walk(element: targetWindow, depth: 0, nodes: &nodes, counter: &counter)
        guard !nodes.isEmpty else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.accessibilityError.rawValue,
                errorName: .accessibilityError,
                message: "Accessibility tree is empty for pid \(pid) (\(appID)).",
                requestType: "getAppState"
            )
        }
        let text = serialize(nodes: nodes, windowTitle: windowTitle, windowFrame: windowFrame, appID: appID)
        return SkyAXSnapshot(
            appID: appID,
            pid: pid,
            windowTitle: windowTitle,
            windowFrame: windowFrame,
            nodes: nodes,
            text: text,
            capturedAt: Date()
        )
    }

    /// Walk a standalone AXUIElement root (used by tests with injected fixtures).
    public static func capture(root: AXUIElement, appID: String = "test") -> SkyAXSnapshot {
        var nodes: [SkyAXNode] = []
        var counter = 0
        walk(element: root, depth: 0, nodes: &nodes, counter: &counter)
        let text = serialize(nodes: nodes, windowTitle: nil, windowFrame: nil, appID: appID)
        return SkyAXSnapshot(
            appID: appID,
            pid: 0,
            windowTitle: nil,
            windowFrame: nil,
            nodes: nodes,
            text: text,
            capturedAt: Date()
        )
    }

    // MARK: - Walk

    static func walk(
        element: AXUIElement,
        depth: Int,
        nodes: inout [SkyAXNode],
        counter: inout Int
    ) {
        guard depth <= maxDepth, nodes.count < maxNodes else { return }

        let role = (try? stringValue(element, roleAttr)) ?? nil
        let index = counter
        counter += 1

        let title = (try? stringValue(element, titleAttr)) ?? nil
        let value = (try? valueString(element)) ?? nil
        let help = (try? stringValue(element, helpAttr)) ?? nil
        let frame = try? frameValue(element)
        let actions = (try? actionNames(element)) ?? []
        let editable = isEditableElement(element, role: role)
        let canSelect = (try? hasSelectedTextRange(element)) ?? false
        var childCount = 0

        var node = SkyAXNode(
            elementIndex: index,
            role: role ?? "unknown",
            title: title,
            value: value,
            help: help,
            frame: frame,
            actions: actions,
            isEditable: editable,
            supportsTextSelection: canSelect
        )
        nodes.append(node)

        var children: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, childrenAttr as CFString, &children)
        if err == .success, let cfList = children, let list = cfList as? [AXUIElement] {
            childCount = list.count
            for child in list {
                walk(element: child, depth: depth + 1, nodes: &nodes, counter: &counter)
                if nodes.count >= maxNodes { break }
            }
        }
        // Patch child count (value types: replace in place).
        let patched = SkyAXNode(
            elementIndex: index,
            role: node.role,
            title: node.title,
            value: node.value,
            help: node.help,
            frame: node.frame,
            actions: node.actions,
            isEditable: node.isEditable,
            supportsTextSelection: node.supportsTextSelection,
            childCount: childCount
        )
        nodes[index] = patched
    }

    // MARK: - Serialization

    /// Condensed text format:
    ///   window "Title" [0] frame=...
    ///   [1] AXButton "OK" frame=(x,y,w,h) actions=(AXPress)
    ///   [2] AXTextField "Search" value="hello" editable
    public static func serialize(
        nodes: [SkyAXNode],
        windowTitle: String?,
        windowFrame: SkyAXFrame?,
        appID: String
    ) -> String {
        var lines: [String] = []
        lines.append("app=\(appID) window=\(windowTitle ?? "<untitled>") elements=\(nodes.count)")
        for node in nodes {
            var parts: [String] = []
            parts.append("[\(node.elementIndex)]")
            parts.append(node.role)
            if let title = node.title, !title.isEmpty {
                parts.append("title=\(escape(title))")
            }
            if let value = node.value, !value.isEmpty {
                parts.append("value=\(escape(value))")
            }
            if let frame = node.frame {
                parts.append(
                    String(
                        format: "frame=(%.0f,%.0f,%.0fx%.0f)",
                        frame.x, frame.y, frame.width, frame.height
                    )
                )
            }
            if node.isEditable {
                parts.append("editable")
            }
            if !node.actions.isEmpty {
                parts.append("actions=(\(node.actions.joined(separator: ",")))")
            }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        // Keep output single-line per element; escape newlines and ] in values.
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Attribute helpers

    static func stringValue(_ element: AXUIElement, _ attr: String) throws -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    static func valueString(_ element: AXUIElement) throws -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, valueAttr as CFString, &value)
        guard err == .success else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let u = value as? URL { return u.absoluteString }
        return nil
    }

    static func boolValue(_ element: AXUIElement, _ attr: String) throws -> Bool {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard err == .success else { return false }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }

    static func arrayValue(_ element: AXUIElement, _ attr: String) throws -> CFArray {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard err == .success, let arr = value else {
            throw SkyComputerUseError(
                code: 0,
                errorName: .accessibilityError,
                message: "missing attribute \(attr)",
                requestType: "ax"
            )
        }
        return arr as! CFArray
    }

    static func fetchWindow(_ appElement: AXUIElement, _ attr: String) throws -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, attr as CFString, &value)
        guard err == .success else { return nil }
        return value as! AXUIElement?
    }

    static func frameValue(_ element: AXUIElement) throws -> SkyAXFrame? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        let errPos = AXUIElementCopyAttributeValue(element, positionAttr as CFString, &pos)
        let errSize = AXUIElementCopyAttributeValue(element, sizeAttr as CFString, &size)
        guard errPos == .success, errSize == .success else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        var typeP = CGPoint.zero
        var typeS = CGSize.zero
        guard
            AXValueGetValue(pos as! AXValue, .cgPoint, &p),
            AXValueGetValue(size as! AXValue, .cgSize, &s)
        else { return nil }
        _ = typeP
        _ = typeS
        return SkyAXFrame(x: p.x, y: p.y, width: s.width, height: s.height)
    }

    static func actionNames(_ element: AXUIElement) throws -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyActionNames(element, &names)
        guard err == .success, let list = names as? [String] else { return [] }
        return list
    }

    static func hasSelectedTextRange(_ element: AXUIElement) throws -> Bool {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, selectedTextRangeAttr as CFString, &value)
        return err == .success && value != nil
    }

    /// Editability heuristic on public APIs: a role known to be editable, or
    /// any element whose AXValue is writable via AXUIElementSetAttributeValue
    /// probe is NOT attempted here (side effects); instead we trust the
    /// AXEditableValue protocol conformance reported through AXValue being
    /// settable via `AXUIElementIsAttributeSettable`.
    static func isEditableElement(_ element: AXUIElement, role: String?) -> Bool {
        let editableRoles: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
            "AXStaticText", "AXCell",
        ]
        if let role, editableRoles.contains(role) {
            // StaticText is only "editable" when it supports text selection.
            if role == "AXStaticText" {
                return (try? hasSelectedTextRange(element)) ?? false
            }
            return true
        }
        // Attribute-settable check for AXValue on anything else.
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, valueAttr as CFString, &settable)
        return err == .success && settable.boolValue
    }
}
