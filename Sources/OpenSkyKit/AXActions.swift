import ApplicationServices
import CoreGraphics
import Foundation

/// AX-level element actions (setValue, selectText, performSecondaryAction)
/// built on public AXUIElement APIs. Index resolution goes through the
/// walker's snapshot indices.
public enum SkyAXActions {

    /// Locate the AXUIElement for an elementIndex by re-walking from the app's
    /// focused/main window and stopping at the target index. Index stability
    /// comes from the same depth-first order used by SkyAXWalker.
    public static func element(
        pid: pid_t,
        index: Int,
        snapshot: SkyAXSnapshot? = nil
    ) throws -> AXUIElement {
        precondition(index >= 0, "elementIndex must be >= 0")
        let appElement = AXUIElementCreateApplication(pid)
        // Walk again in identical order and pick the node at `index`.
        let fresh = try SkyAXWalker.captureApp(pid: Int(pid), appID: "resolve")
        guard index < fresh.nodes.count else {
            throw SkyComputerUseError(
                code: 0,
                errorName: .elementNotFound,
                message: "elementIndex \(index) out of range (tree has \(fresh.nodes.count) elements). Take a fresh get_app_state.",
                requestType: "element"
            )
        }
        let path = pathToIndex(root: appElement, targetIndex: index)
        guard let resolved = path else {
            throw SkyComputerUseError(
                code: 0,
                errorName: .elementNotFound,
                message: "elementIndex \(index) no longer resolves in the live tree.",
                requestType: "element"
            )
        }
        return resolved
    }

    /// Walk children depth-first, mirroring SkyAXWalker.walk ordering, and
    /// return the element whose visit order equals `targetIndex`.
    static func pathToIndex(root: AXUIElement, targetIndex: Int) -> AXUIElement? {
        var counter = -1
        return dfs(element: root, depth: 0, counter: &counter, targetIndex: targetIndex)
    }

    static func dfs(
        element: AXUIElement,
        depth: Int,
        counter: inout Int,
        targetIndex: Int
    ) -> AXUIElement? {
        guard depth <= SkyAXWalker.maxDepth else { return nil }
        counter += 1
        if counter == targetIndex { return element }
        var children: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element,
            SkyAXWalker.childrenAttr as CFString,
            &children
        )
        guard err == .success, let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let hit = dfs(element: child, depth: depth + 1, counter: &counter, targetIndex: targetIndex) {
                return hit
            }
        }
        return nil
    }

    // MARK: - setValue

    /// Replace the value of an indexed editable element (AXValue set).
    public static func setValue(
        pid: pid_t,
        elementIndex: Int,
        value: String
    ) throws {
        let element = try self.element(pid: pid, index: elementIndex)
        let editable = SkyAXWalker.isEditableElement(
            element,
            role: (try? SkyAXWalker.stringValue(element, SkyAXWalker.roleAttr)) ?? nil
        )
        guard editable else {
            throw SkyComputerUseError(
                code: 0,
                errorName: .unsupportedAction,
                message: "Element \(elementIndex) is not editable.",
                requestType: "setValue"
            )
        }
        var cfValue: CFTypeRef = value as CFTypeRef
        let err = AXUIElementSetAttributeValue(
            element,
            SkyAXWalker.valueAttr as CFString,
            cfValue
        )
        cfValue = kCFNull as CFTypeRef
        _ = cfValue
        guard err == .success else {
            throw axError(err, requestType: "setValue", detail: "AXValue set on element \(elementIndex)")
        }
    }

    // MARK: - performSecondaryAction

    /// Invoke a named AX action on an indexed element (e.g. AXPress, AXPick).
    public static func performSecondaryAction(
        pid: pid_t,
        elementIndex: Int,
        action: String
    ) throws {
        let element = try self.element(pid: pid, index: elementIndex)
        let names = (try? SkyAXWalker.actionNames(element)) ?? []
        let resolved = names.first { $0.caseInsensitiveCompare(action) == .orderedSame }
        guard let resolved else {
            throw SkyComputerUseError(
                code: 0,
                errorName: .unsupportedAction,
                message: "Element \(elementIndex) has no action '\(action)' (available: \(names.joined(separator: ", "))).",
                requestType: "performSecondaryAction"
            )
        }
        let err = AXUIElementPerformAction(element, resolved as CFString)
        guard err == .success else {
            throw axError(err, requestType: "performSecondaryAction", detail: "\(resolved) on element \(elementIndex)")
        }
    }

    // MARK: - selectText

    /// Select text in an indexed editable element.
    /// `selection`: .text selects the match; cursor_before/after place caret.
    public static func selectText(
        pid: pid_t,
        elementIndex: Int,
        text: String,
        prefix: String? = nil,
        suffix: String? = nil,
        selection: SkySelectionType = .text
    ) throws {
        let element = try self.element(pid: pid, index: elementIndex)
        guard let full = try SkyAXWalker.valueString(element), !full.isEmpty else {
            throw SkyComputerUseError(
                code: 0,
                errorName: .elementNotFound,
                message: "Element \(elementIndex) has no readable text value.",
                requestType: "selectText"
            )
        }
        let lower = full.lowercased()
        let needle = text.lowercased()
        guard let matchRange = lower.range(of: needle) else {
            throw SkyComputerUseError(
                code: 0,
                errorName: .elementNotFound,
                message: "Text '\(text)' not found in element \(elementIndex).",
                requestType: "selectText"
            )
        }
        // Disambiguate with prefix/suffix when provided.
        var candidate = matchRange
        if let prefix {
            let prefixLower = prefix.lowercased()
            var searchStart = lower.startIndex
            var found: Range<String.Index>? = nil
            while let r = lower.range(of: needle, range: searchStart..<lower.endIndex) {
                let before = lower.startIndex..<r.lowerBound
                if lower[before].hasSuffix(prefixLower) {
                    found = r
                    break
                }
                searchStart = r.upperBound
            }
            guard let chosen = found else {
                throw SkyComputerUseError(
                    code: 0,
                    errorName: .elementNotFound,
                    message: "No occurrence of '\(text)' preceded by '\(prefix)' in element \(elementIndex).",
                    requestType: "selectText"
                )
            }
            candidate = chosen
        }
        if let suffix {
            let suffixLower = suffix.lowercased()
            let after = lower[candidate.upperBound...]
            guard after.hasPrefix(suffixLower) else {
                throw SkyComputerUseError(
                    code: 0,
                    errorName: .elementNotFound,
                    message: "Occurrence of '\(text)' is not followed by '\(suffix)' in element \(elementIndex).",
                    requestType: "selectText"
                )
            }
        }

        // Convert character offsets to UTF-16 for AX.
        let utf16 = Array(full.utf16)
        let start16 = utf16.distance(
            from: utf16.startIndex,
            to: full.utf16.distance(from: full.utf16.startIndex, to: candidate.lowerBound.samePosition(in: full.utf16) ?? full.utf16.startIndex)
        )
        let length16 = text.utf16.count
        _ = start16

        let startOffset = utf16Offset(of: candidate.lowerBound, in: full)
        let selLength = length16

        switch selection {
        case .text:
            try setSelectedRange(element, start: startOffset, length: selLength, elementIndex: elementIndex)
        case .cursorBefore:
            try setSelectedRange(element, start: startOffset, length: 0, elementIndex: elementIndex)
        case .cursorAfter:
            try setSelectedRange(element, start: startOffset + selLength, length: 0, elementIndex: elementIndex)
        }
    }

    static func utf16Offset(of index: String.Index, in string: String) -> Int {
        string.utf16.distance(from: string.utf16.startIndex, to: index.samePosition(in: string.utf16) ?? string.utf16.startIndex)
    }

    static func setSelectedRange(
        _ element: AXUIElement,
        start: Int,
        length: Int,
        elementIndex: Int
    ) throws {
        // KAXSelectedTextRange uses CFRange {location, length}.
        var range = CFRange(location: start, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.internalError.rawValue,
                errorName: .internalError,
                message: "AXValueCreate failed for selected text range.",
                requestType: "selectText"
            )
        }
        let err = AXUIElementSetAttributeValue(
            element,
            SkyAXWalker.selectedTextRangeAttr as CFString,
            value
        )
        guard err == .success else {
            throw axError(err, requestType: "selectText", detail: "set selected range on element \(elementIndex)")
        }
    }

    // MARK: - Focus

    /// Bring focus to an indexed element (used before typeText/paste).
    public static func focusElement(pid: pid_t, elementIndex: Int) throws {
        let element = try self.element(pid: pid, index: elementIndex)
        var success: CFTypeRef = kCFBooleanTrue as CFTypeRef
        let err = AXUIElementSetAttributeValue(
            element,
            SkyAXWalker.focusedAttr as CFString,
            success
        )
        _ = success
        success = kCFBooleanFalse as CFTypeRef
        guard err == .success else {
            throw axError(err, requestType: "focus", detail: "focus element \(elementIndex)")
        }
    }

    // MARK: - Errors

    static func axError(_ status: AXError, requestType: String, detail: String) -> SkyComputerUseError {
        let name: SkyComputerUseErrorName
        let code: SkyComputerUseErrorCode
        switch status {
        case .apiDisabled, .notImplemented:
            name = .permissionsNotGranted
            code = .permissionsNotGranted
        case .cannotComplete, .failure:
            name = .accessibilityError
            code = .accessibilityError
        case .attributeUnsupported, .actionUnsupported:
            name = .unsupportedAction
            code = .noCode
        case .noValue:
            name = .elementNotFound
            code = .noCode
        case .invalidUIElement:
            name = .elementNotFound
            code = .noCode
        default:
            name = .accessibilityError
            code = .accessibilityError
        }
        return SkyComputerUseError(
            code: code.rawValue,
            errorName: name,
            message: "\(detail): AXError \(status.rawValue)",
            requestType: requestType
        )
    }
}
