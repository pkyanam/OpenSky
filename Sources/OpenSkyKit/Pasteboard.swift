import AppKit
import Foundation

/// Clipboard save/write/restore used by `paste` (public NSPasteboard API).
public struct SkyPasteboardData: Sendable {
    public enum Payload: Sendable {
        case plain(String)
        case html(String)
        case markdown(String)
    }

    public let payload: Payload
}

public struct SkyPasteboardSnapshot: Sendable {
    /// Serialized change-count so restore skips redundant work.
    public let changeCount: Int
    /// Raw pasteboard contents at save time.
    public let items: [[String: Data]]
}

/// NSPasteboard wrapper: encode per format, save, write, restore.
public struct SkyPasteboard {
    public init() {}

    /// Encode content to pasteboard payload per spec format (text|md|html).
    public func encode(text: String, format: SkyPasteFormat) throws -> SkyPasteboardData {
        switch format {
        case .text:
            return SkyPasteboardData(payload: .plain(text))
        case .html:
            return SkyPasteboardData(payload: .html(text))
        case .md:
            // Markdown goes on the board as plain text (apps paste source).
            return SkyPasteboardData(payload: .markdown(text))
        }
    }

    /// Save current contents for later restore.
    public func save() throws -> SkyPasteboardSnapshot {
        let pb = NSPasteboard.general
        var items: [[String: Data]] = []
        for item in (pb.pasteboardItems ?? []) {
            let types = (item.types ?? []).compactMap { $0.rawValue }
            var entry: [String: Data] = [:]
            for type in types {
                if let data = item.data(forType: NSPasteboard.PasteboardType(rawValue: type)) {
                    entry[type] = data
                }
            }
            items.append(entry)
        }
        return SkyPasteboardSnapshot(changeCount: pb.changeCount, items: items)
    }

    /// Write the payload to the general pasteboard.
    public func write(_ data: SkyPasteboardData) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch data.payload {
        case .plain(let text):
            pb.setString(text, forType: .string)
        case .markdown(let text):
            pb.setString(text, forType: .string)
        case .html(let html):
            pb.setString(html, forType: .html)
            // Plain-text fallback improves paste compatibility.
            pb.setString(html, forType: .string)
        }
    }

    /// Restore a snapshot (noop when unchanged).
    public func restore(_ snapshot: SkyPasteboardSnapshot) {
        let pb = NSPasteboard.general
        guard pb.changeCount != snapshot.changeCount else { return }
        pb.clearContents()
        for entry in snapshot.items {
            let types = entry.keys.map { NSPasteboard.PasteboardType(rawValue: $0) }
            guard !types.isEmpty else { continue }
            for type in types {
                if let data = entry[type.rawValue] {
                    pb.setData(data, forType: type)
                }
            }
        }
    }
}
