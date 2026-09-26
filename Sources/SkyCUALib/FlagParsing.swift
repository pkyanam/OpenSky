import Foundation

/// Simple CLI flag parsing shared by the sky-cua executable; exposed through
/// SkyCUALib so the XCTest suite can exercise the same parsing path.
public struct SkyFlags {
    public var raw: [String]

    public init(raw: [String]) {
        self.raw = raw
    }

    mutating func value(_ short: String, _ long: String) -> String? {
        guard let at = raw.firstIndex(where: { $0 == short || $0 == long }) else { return nil }
        let next = raw.index(after: at)
        guard next < raw.endIndex else { return nil }
        defer { raw.removeSubrange(at...next) }
        return raw[next]
    }

    public func stringFlag(_ short: String, _ long: String) -> String? {
        var copy = self
        return copy.value(short, long)
    }

    public func intFlag(_ short: String, _ long: String) -> Int? {
        stringFlag(short, long).flatMap(Int.init)
    }

    public func doubleFlag(_ short: String, _ long: String) -> Double? {
        stringFlag(short, long).flatMap(Double.init)
    }

    public func buttonFlag(_ short: String, _ long: String) -> SkyMouseButton? {
        stringFlag(short, long).flatMap(SkyMouseButton.init)
    }
}

public enum SkyFlagParsing {
    public static func parse(_ args: [String]) -> SkyFlags {
        SkyFlags(raw: args)
    }
}
