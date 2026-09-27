import ApplicationServices
import AppKit
import XCTest
@testable import OpenSkyKit

/// A minimal NSWindow-based stub app that publishes a real AXUIElement tree
/// inside the test process — no ChatGPT.app or external application required.
final class TestStubAXApp: NSObject {
    let window: NSWindow
    let labelView: AXStubView
    let buttonView: AXStubView
    let fieldView: AXStubView

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: -4200, y: -4200, width: 420, height: 300), // off-screen: never disturb the user
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stub Window"
        // Invisible to the user: transparent + off-screen. AX still sees it
        window.alphaValue = 0.01

        labelView = AXStubView(frame: NSRect(x: 10, y: 260, width: 200, height: 20))
        labelView.setAccessibilityRole(.staticText)
        labelView.setAccessibilityValue("Hello OpenSky")

        buttonView = AXStubView(frame: NSRect(x: 10, y: 20, width: 80, height: 30))
        buttonView.setAccessibilityRole(.button)
        buttonView.setAccessibilityTitle("OK")

        fieldView = AXStubView(frame: NSRect(x: 10, y: 100, width: 300, height: 24))
        fieldView.setAccessibilityRole(.textField)
        fieldView.setAccessibilityValue("editable text")

        window.contentView?.addSubview(labelView)
        window.contentView?.addSubview(buttonView)
        window.contentView?.addSubview(fieldView)
        super.init()
    }

    /// Order the window on screen so the AX hierarchy becomes visible to
    /// AXUIElementCreateApplication(getpid()), and spin the runloop once.
    func activateForAX() -> Bool {
        _ = NSApplication.shared
        // CLI test processes default to .prohibited; become accessory so the
        // window registers with the window server.
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Give AppKit a beat to publish the window.
        for _ in 0..<40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if firstWindowElement() != nil { return true }
        }
        return false
    }

    /// Diagnostic for skip messages: does the window server know this window?
    var windowNumber: Int { Int(window.windowNumber) }

    /// Own process → first window element (kAXWindowsAttribute, with
    /// main/focused-window fallbacks).
    func firstWindowElement() -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid_t(getpid()))
        let attributes = [
            kAXWindowsAttribute as String,
            kAXFocusedWindowAttribute as String,
            kAXMainWindowAttribute as String,
        ]
        for attr in attributes {
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(appElement, attr as CFString, &value)
            if err == .success, let list = value as? [AXUIElement], !list.isEmpty {
                return list.first
            }
        }
        return nil
    }
}

/// Leaf NSView with an explicit AX role/title/value; children via the
/// accessibility-children protocol (default = subviews).
final class AXStubView: NSView {
    override func isAccessibilityElement() -> Bool { true }
}

// MARK: - Tests

final class AXWalkIndexingTests: XCTestCase {

    private func makeActivatedStub() throws -> TestStubAXApp {
        // Off-screen + sub-normal level: the window must exist for AX, but
        // must never visually disturb the user (blank "Stub Window" flashes).

        let stub = TestStubAXApp()
        guard stub.activateForAX() else {
            throw XCTSkip(
                "AX window unavailable in this test environment (windowNumber=\(stub.windowNumber), pid=\(getpid()))"
            )
        }
        return stub
    }

    /// Root of the walk = our stub process's first AX window element.
    private func captureStub(_ stub: TestStubAXApp) throws -> SkyAXSnapshot {
        let root = try XCTUnwrap(stub.firstWindowElement(), "no AX window element")
        return SkyAXWalker.capture(root: root, appID: "stub")
    }

    func testDepthFirstOrderingAndIndices() throws {
        let stub = try makeActivatedStub()
        let snapshot = try captureStub(stub)

        // Indices must equal array position (stable, dense, depth-first).
        for (i, node) in snapshot.nodes.enumerated() {
            XCTAssertEqual(node.elementIndex, i, "index mismatch at position \(i)")
        }

        // Roles of the stub leaves, in depth-first visit order.
        let leafRoles = snapshot.nodes
            .filter { ["AXStaticText", "AXButton", "AXTextField"].contains($0.role) }
            .map { $0.role }
        XCTAssertEqual(leafRoles, ["AXStaticText", "AXButton", "AXTextField"])

        // Title/value round-trips.
        let button = try XCTUnwrap(snapshot.nodes.first { $0.role == "AXButton" })
        XCTAssertEqual(button.title, "OK")
        let field = try XCTUnwrap(snapshot.nodes.first { $0.role == "AXTextField" })
        XCTAssertEqual(field.value, "editable text")
        let label = try XCTUnwrap(snapshot.nodes.first { $0.role == "AXStaticText" })
        XCTAssertEqual(label.value, "Hello OpenSky")
    }

    func testIndexStabilityAcrossRepeatedWalks() throws {
        let stub = try makeActivatedStub()
        let first = try captureStub(stub)
        let second = try captureStub(stub)

        XCTAssertEqual(first.nodes.count, second.nodes.count)
        for (a, b) in zip(first.nodes, second.nodes) {
            XCTAssertEqual(a.elementIndex, b.elementIndex)
            XCTAssertEqual(a.role, b.role)
            XCTAssertEqual(a.title, b.title)
            XCTAssertEqual(a.value, b.value)
        }
    }

    func testNodeLookupAndOutOfRange() throws {
        let stub = try makeActivatedStub()
        let snapshot = try captureStub(stub)
        let buttonIndex = try XCTUnwrap(
            snapshot.nodes.first { $0.role == "AXButton" }?.elementIndex
        )

        XCTAssertEqual(snapshot.node(at: buttonIndex)?.role, "AXButton")
        XCTAssertEqual(snapshot.node(at: 0)?.role, snapshot.nodes.first?.role)
        XCTAssertNil(snapshot.node(at: -1))
        XCTAssertNil(snapshot.node(at: snapshot.nodes.count))
    }

    func testSerializedTextEmbedsIndices() throws {
        let stub = try makeActivatedStub()
        let snapshot = try captureStub(stub)

        XCTAssertTrue(snapshot.text.hasPrefix("app=stub"), "header: \(snapshot.text.prefix(60))")
        XCTAssertTrue(snapshot.text.contains("elements=\(snapshot.nodes.count)"))
        // Every element index appears as a [N] marker in the text.
        for node in snapshot.nodes {
            XCTAssertTrue(
                snapshot.text.contains("[\(node.elementIndex)] \(node.role)"),
                "missing marker for \(node.elementIndex)"
            )
        }
        // Editable flag on the text field role; not on the button.
        let fieldLine = snapshot.text.components(separatedBy: "\n")
            .first { $0.contains("AXTextField") }
        XCTAssertTrue(fieldLine?.contains("editable") ?? false)
    }
}
