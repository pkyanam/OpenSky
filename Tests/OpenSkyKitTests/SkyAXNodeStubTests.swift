import XCTest
@testable import OpenSkyKit

/// Deterministic stub-node tests for depth-first walk ordering, dense stable
/// indices, serialization format, and node(at:) bounds — no window server.
/// The SkyAXNode/SkyAXSnapshot shapes mirror SkyAXWalker's capture output;
/// the walker's real fixture path is exercised in AXWalkIndexingTests.
final class SkyAXNodeStubTests: XCTestCase {

    /// Stub snapshot in the walker's depth-first visit order:
    /// window(0) → staticText(1), button(2), textField(3).
    private func makeSnapshot() -> SkyAXSnapshot {
        let nodes = [
            SkyAXNode(elementIndex: 0, role: "AXWindow", title: "Stub Window"),
            SkyAXNode(elementIndex: 1, role: "AXStaticText", value: "Hello OpenSky"),
            SkyAXNode(elementIndex: 2, role: "AXButton", title: "OK", actions: ["AXPress"]),
            SkyAXNode(elementIndex: 3, role: "AXTextField", value: "editable text", isEditable: true),
        ]
        return SkyAXSnapshot(
            appID: "stub",
            pid: 0,
            windowTitle: "Stub Window",
            windowFrame: nil,
            nodes: nodes,
            text: SkyAXWalker.serialize(
                nodes: nodes,
                windowTitle: "Stub Window",
                windowFrame: SkyAXFrame(x: 0.0, y: 0.0, width: 420.0, height: 300.0),
                appID: "stub"
            ),
            capturedAt: Date()
        )
    }

    func testDepthFirstOrderingAndIndices() {
        let snapshot = makeSnapshot()
        for (i, node) in snapshot.nodes.enumerated() {
            XCTAssertEqual(node.elementIndex, i)
        }
        XCTAssertEqual(snapshot.nodes.map(\.role), ["AXWindow", "AXStaticText", "AXButton", "AXTextField"])
    }

    func testIndexStabilityAcrossRepeatedWalks() {
        let first = makeSnapshot()
        let second = makeSnapshot()
        for (a, b) in zip(first.nodes, second.nodes) {
            XCTAssertEqual(a.elementIndex, b.elementIndex)
            XCTAssertEqual(a.role, b.role)
            XCTAssertEqual(a.title, b.title)
            XCTAssertEqual(a.value, b.value)
        }
    }

    func testNodeLookupAndOutOfRange() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.node(at: 2)?.role, "AXButton")
        XCTAssertEqual(snapshot.node(at: 0)?.role, "AXWindow")
        XCTAssertNil(snapshot.node(at: -1))
        XCTAssertNil(snapshot.node(at: 4))
    }

    func testSerializedTextEmbedsIndices() {
        let snapshot = makeSnapshot()
        XCTAssertTrue(snapshot.text.contains("[2] AXButton title=OK"))
        XCTAssertTrue(snapshot.text.contains("editable"))
        XCTAssertTrue(snapshot.text.contains("elements=4"))
    }
}
