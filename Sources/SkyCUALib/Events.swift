import CoreGraphics
import Foundation

/// CGEvent-based input synthesis (public CoreGraphics API).
public enum SkyEventSynthesizer {

    // MARK: - Mouse

    public enum SkyMouseButtonType {
        case left, right, middle
    }

    static func cgButton(_ button: SkyMouseButtonType) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    /// Post a full click (down+up) at a global point.
    public static func click(
        at point: CGPoint,
        button: SkyMouseButtonType = .left,
        clickCount: Int = 1
    ) throws {
        guard point.x.isFinite, point.y.isFinite else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.invalidApp.rawValue,
                errorName: .invalidApp,
                message: "Invalid click coordinates \(point).",
                requestType: "click"
            )
        }
        let cg = cgButton(button)
        let down = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseDownType(button, clickCount),
            mouseCursorPosition: point,
            mouseButton: cg
        )
        down?.setIntegerValueField(.mouseEventClickState, value: Int64(CGWindowClickCount(clickCount)))
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseUpType(button, clickCount),
            mouseCursorPosition: point,
            mouseButton: cg
        )
        up?.setIntegerValueField(.mouseEventClickState, value: Int64(CGWindowClickCount(clickCount)))
        try post(down, "click")
        try post(up, "click")
    }

    /// Move the cursor to a point (no button).
    public static func move(to point: CGPoint) throws {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        try post(event, "move")
    }

    /// Press the button down at a point and hold.
    public static func mouseDown(at point: CGPoint, button: SkyMouseButtonType = .left) throws {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseDownType(button, 1),
            mouseCursorPosition: point,
            mouseButton: cgButton(button)
        )
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        try post(event, "drag")
    }

    /// Release the pressed button at a point.
    public static func mouseUp(at point: CGPoint, button: SkyMouseButtonType = .left) throws {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseUpType(button, 1),
            mouseCursorPosition: point,
            mouseButton: cgButton(button)
        )
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        try post(event, "drag")
    }

    /// Drag: press at `from`, move in steps, release at `to`.
    public static func drag(from: CGPoint, to: CGPoint, steps: Int = 12) throws {
        try mouseDown(at: from)
        // Interpolate to give apps time to register the drag.
        for i in 1...max(1, steps) {
            let t = Double(i) / Double(max(1, steps))
            let p = CGPoint(
                x: from.x + (to.x - from.x) * t,
                y: from.y + (to.y - from.y) * t
            )
            try move(to: p)
            Thread.sleep(forTimeInterval: 0.012)
        }
        try mouseUp(at: to)
    }

    /// Scroll by lines at a point.
    public static func scroll(at point: CGPoint, linesDown: Double) throws {
        // CGScrollEvent units: line-based wheel events.
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: Int32(-linesDown),
            wheel2: 0,
            wheel3: 0
        )
        event?.location = point
        try post(event, "scroll")
    }

    /// Horizontal scroll (positive = right).
    public static func scrollHorizontal(at point: CGPoint, linesRight: Double) throws {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 0,
            wheel2: Int32(linesRight),
            wheel3: 0
        )
        event?.location = point
        try post(event, "scroll")
    }

    // MARK: - Keyboard

    /// Press a key chord. Key names are X11-keysym-style per the spec
    /// ("a", "space", "Return", "Tab", "Control_L+a", "Super_L+d").
    public static func pressKey(_ chord: String) throws {
        let parsed = try SkyKeyMap.parse(chord)
        var flags = CGEventFlags()
        for m in parsed.modifiers {
            flags = flags.union(m.cgFlags)
        }
        // If modifiers present but no base key (e.g. "Control_L"), send modifier tap.
        if let base = parsed.key {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: base.keyCode, keyDown: true)
            down?.flags = flags
            try post(down, "pressKey")
            let up = CGEvent(keyboardEventSource: nil, virtualKey: base.keyCode, keyDown: false)
            up?.flags = flags
            try post(up, "pressKey")
        } else {
            // Tap each modifier down+up.
            for m in parsed.modifiers {
                let code = m.modifierKeyCode
                let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
                try post(down, "pressKey")
                let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
                try post(up, "pressKey")
            }
        }
    }

    /// Type a string via Unicode string events (handles emoji/intl chars).
    public static func typeText(_ text: String) throws {
        for char in text {
            let scalar = String(char)
            var utf16 = Array(scalar.utf16)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            try post(down, "typeText")
            var upUtf16 = Array(scalar.utf16)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: upUtf16.count, unicodeString: &upUtf16)
            try post(up, "typeText")
        }
    }

    // MARK: - Internals

    @discardableResult
    static func post(_ event: CGEvent?, _ requestType: String) throws -> CGEvent? {
        guard let event else {
            throw SkyComputerUseError(
                code: SkyComputerUseErrorCode.internalError.rawValue,
                errorName: .internalError,
                message: "CGEvent creation failed.",
                requestType: requestType
            )
        }
        event.post(tap: .cghidEventTap)
        return event
    }

    static func mouseDownType(_ button: SkyMouseButtonType, _ count: Int) -> CGEventType {
        let base: CGEventType
        switch button {
        case .left: base = .leftMouseDown
        case .right: base = .rightMouseDown
        case .middle: base = .otherMouseDown
        }
        if count == 2 { return base } // clickState handles multiplicity
        return base
    }

    static func mouseUpType(_ button: SkyMouseButtonType, _ count: Int) -> CGEventType {
        switch button {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    static func CGWindowClickCount(_ count: Int) -> Int {
        // clickState 1..3; >3 clamps to 3.
        return min(max(count, 1), 3)
    }
}

/// One parsed key map entry.
public struct SkyKeyMapEntry: Sendable, Equatable {
    public let name: String
    public let keyCode: CGKeyCode

    public init(name: String, keyCode: CGKeyCode) {
        self.name = name
        self.keyCode = keyCode
    }
}

public enum SkyModifierKey: String, Sendable, CaseIterable {
    case controlL = "Control_L"
    case controlR = "Control_R"
    case altL = "Alt_L"
    case altR = "Alt_R"
    case shiftL = "Shift_L"
    case shiftR = "Shift_R"
    case superL = "Super_L"
    case superR = "Super_R"
    case metaL = "Meta_L"
    case metaR = "Meta_R"

    public var cgFlags: CGEventFlags {
        switch self {
        case .controlL, .controlR: return .maskControl
        case .altL, .altR: return .maskAlternate
        case .shiftL, .shiftR: return .maskShift
        case .superL, .superR, .metaL, .metaR: return .maskCommand
        }
    }

    public var modifierKeyCode: CGKeyCode {
        // Standard Apple Silicon ANSI keycodes.
        switch self {
        case .controlL: return 59
        case .controlR: return 62
        case .altL: return 58
        case .altR: return 61
        case .shiftL: return 56
        case .shiftR: return 60
        case .superL: return 55
        case .superR: return 54
        case .metaL: return 55
        case .metaR: return 54
        }
    }
}

public struct SkyParsedChord: Sendable {
    public let modifiers: [SkyModifierKey]
    public let key: SkyKeyMapEntry?
}

/// Parses X11-keysym-style chords ("Control_L+a", "Return", "space").
public enum SkyKeyMap {

    /// Alias table: common spec-accepted aliases.
    static let aliases: [String: String] = [
        "ctrl": "Control_L",
        "control": "Control_L",
        "cmd": "Super_L",
        "command": "Super_L",
        "super": "Super_L",
        "meta": "Super_L",
        "alt": "Alt_L",
        "option": "Alt_L",
        "opt": "Alt_L",
        "shift": "Shift_L",
        "esc": "Escape",
        "return": "Return",
        "enter": "Return",
        "del": "Delete", // X11 "Delete" is backspace on mac
        "backspace": "Delete",
        "pgup": "Page_Up",
        "pgdn": "Page_Down",
        "pagedown": "Page_Down",
        "pageup": "Page_Up",
        "arrowup": "Up",
        "arrowdown": "Down",
        "arrowleft": "Left",
        "arrowright": "Right",
    ]

    /// Base keysym -> macOS virtual key code (ANSI layout).
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20,
        "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D,
        "m": 0x2E,
        "Return": 0x24, "Tab": 0x30, "space": 0x31, "Delete": 0x33,
        "Escape": 0x35, "Command_L": 55, "Command_R": 54,
        "Shift_L": 56, "Shift_R": 60, "Caps_Lock": 57,
        "Alt_L": 58, "Alt_R": 61, "Control_L": 59, "Control_R": 62,
        "Right": 124, "Left": 123, "Down": 125, "Up": 126,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
        "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
        "Home": 115, "Page_Up": 116, "End": 119, "Page_Down": 121,
        "Backspace": 51, "Forward_Delete": 117,
        "minus": 27, "equal": 24, "bracket_left": 33, "bracket_right": 30,
        "semicolon": 41, "apostrophe": 39, "comma": 43, "period": 47,
        "slash": 44, "backslash": 42, "grave": 50,
    ]

    public static func parse(_ chord: String) throws -> SkyParsedChord {
        let parts = chord
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            throw SkyComputerUseError(
                code: 0,
                errorName: .unsupportedAction,
                message: "Empty key chord.",
                requestType: "pressKey"
            )
        }

        var modifiers: [SkyModifierKey] = []
        var baseName: String?
        for part in parts {
            let aliased = aliases[part.lowercased()] ?? part
            if let modifier = SkyModifierKey(rawValue: aliased) {
                modifiers.append(modifier)
            } else if
                part.lowercased().hasPrefix("ctrl"),
                let modifier = SkyModifierKey(rawValue: "Control_L")
            {
                modifiers.append(modifier)
            } else {
                // A chord has exactly one base key; reject malformed input
                // like "Frog+3" instead of silently dropping "Frog".
                if baseName != nil {
                    throw SkyComputerUseError(
                        code: 0,
                        errorName: .unsupportedAction,
                        message: "Multiple base keys in chord '\(chord)' (modifiers use + as separator).",
                        requestType: "pressKey"
                    )
                }
                baseName = aliased
            }
        }
        guard baseName != nil || !modifiers.isEmpty else {
            throw SkyComputerUseError(
                code: 0,
                errorName: .unsupportedAction,
                message: "Unrecognized key chord '\(chord)'.",
                requestType: "pressKey"
            )
        }

        var key: SkyKeyMapEntry?
        if let baseName {
            let normalized = normalizeKeyName(baseName)
            guard let code = keyCodes[normalized] else {
                throw SkyComputerUseError(
                    code: 0,
                    errorName: .unsupportedAction,
                    message: "Unknown keysym '\(baseName)' in chord '\(chord)'.",
                    requestType: "pressKey"
                )
            }
            key = SkyKeyMapEntry(name: normalized, keyCode: code)
        }
        return SkyParsedChord(modifiers: modifiers, key: key)
    }

    static func normalizeKeyName(_ name: String) -> String {
        // Canonical capitalizations already in the table.
        if keyCodes[name] != nil { return name }
        // Try lower-case for letters.
        let lowered = name.lowercased()
        if keyCodes[lowered] != nil { return lowered }
        return name
    }
}
