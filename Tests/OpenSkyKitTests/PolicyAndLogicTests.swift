import AppKit
import XCTest
@testable import OpenSkyKit

/// Policy decisions on an isolated UserDefaults suite (no system state).
final class PolicyStoreTests: XCTestCase {

    private func isolatedStore() -> SkyPolicyStore {
        let name = "OpenSky.Tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return SkyPolicyStore(defaults: suite)
    }

    private func target(_ bundleID: String, _ risk: SkyPolicyRisk) -> SkyPolicyTarget {
        SkyPolicyTarget(
            appPath: "/Applications/Stub.app",
            bundleIdentifier: bundleID,
            displayName: "Stub",
            risk: risk
        )
    }

    func testLowRiskAllowedByDefault() {
        let store = isolatedStore()
        let result = store.policy(for: target("com.example.stub", .low))
        XCTAssertEqual(result.decision, .allowed)
        XCTAssertEqual(result.target.risk, .low)
        XCTAssertTrue(result.allowPersistentApproval)
    }

    func testHighRiskDeniedByDefaultThenAllowedAfterApproval() {
        let store = isolatedStore()
        let high = target("com.example.payments", .high)

        // Default deny-high-risk before any approval.
        XCTAssertEqual(store.policy(for: high).decision, .denied)

        // Session approval flips it; persistence remains offered.
        store.approve(bundleID: "com.example.payments", persistent: false)
        let after = store.policy(for: high)
        XCTAssertEqual(after.decision, .allowed)
        XCTAssertTrue(after.allowPersistentApproval)
    }

    func testForbiddenNeverOverridableByApproval() {
        let store = isolatedStore()
        let forbidden = target("com.apple.finder", .low)

        XCTAssertEqual(store.policy(for: forbidden).decision, .forbidden)
        store.approve(bundleID: "com.apple.finder", persistent: true)
        XCTAssertEqual(store.policy(for: forbidden).decision, .forbidden,
                       "approval must not override the safety block list")
        XCTAssertEqual(SkyPolicyStore.error(for: store.policy(for: forbidden))?.errorName, .policyForbidden)
    }

    func testExplicitDenyWins() {
        let store = isolatedStore()
        let denied = target("com.example.blocked", .low)

        store.deny(bundleID: "com.example.blocked")
        XCTAssertEqual(store.policy(for: denied).decision, .denied)
        XCTAssertEqual(SkyPolicyStore.error(for: store.policy(for: denied))?.errorName, .appNotAllowed)

        // Even an approval attempt is wiped by deny().
        store.approve(bundleID: "com.example.blocked", persistent: false)
        XCTAssertEqual(store.policy(for: denied).decision, .denied)
    }

    func testRevokeRestoresDefaultDenyForHighRisk() {
        let store = isolatedStore()
        let high = target("com.example.volatile", .high)
        store.approve(bundleID: "com.example.volatile", persistent: true)
        XCTAssertEqual(store.policy(for: high).decision, .allowed)

        store.revoke(bundleID: "com.example.volatile")
        XCTAssertEqual(store.policy(for: high).decision, .denied)
    }
}

/// X11-keysym-style chord parsing (pure logic).
final class KeyMapParsingTests: XCTestCase {

    func testSimpleKey() throws {
        let parsed = try SkyKeyMap.parse("Return")
        XCTAssertTrue(parsed.modifiers.isEmpty)
        XCTAssertEqual(parsed.key?.name, "Return")
        XCTAssertEqual(parsed.key?.keyCode, 0x24)
    }

    func testModifierChordWithAliases() throws {
        let parsed = try SkyKeyMap.parse("ctrl+a")
        XCTAssertEqual(parsed.modifiers, [.controlL])
        XCTAssertEqual(parsed.key?.name, "a")

        let cmd = try SkyKeyMap.parse("cmd+shift+t")
        XCTAssertEqual(cmd.modifiers, [.superL, .shiftL])
        XCTAssertEqual(cmd.key?.name, "t")
    }

    func testModifierOnlyChord() throws {
        let parsed = try SkyKeyMap.parse("Control_L")
        XCTAssertEqual(parsed.modifiers, [.controlL])
        XCTAssertNil(parsed.key)
    }

    func testUnknownKeyThrows() {
        XCTAssertThrowsError(try SkyKeyMap.parse("Frog+3")) { error in
            let skyError = try? XCTUnwrap(error as? SkyComputerUseError)
            XCTAssertEqual(skyError?.errorName, .unsupportedAction)
        }
    }

    func testEmptyChordThrows() {
        XCTAssertThrowsError(try SkyKeyMap.parse(""))
    }

    func testDirectionAliases() {
        XCTAssertEqual(SkyDirection(rawValue: "u")?.canonical, .up)
        XCTAssertEqual(SkyDirection(rawValue: "d")?.canonical, .down)
        XCTAssertEqual(SkyDirection(rawValue: "l")?.canonical, .left)
        XCTAssertEqual(SkyDirection(rawValue: "r")?.canonical, .right)
        XCTAssertEqual(SkyMouseButton(rawValue: "l")?.canonical, .left)
        XCTAssertEqual(SkyMouseButton(rawValue: "m")?.canonical, .middle)
    }
}

/// Pasteboard encode/save/write/restore on the real NSPasteboard.
final class PasteboardTests: XCTestCase {

    func testEncodeFormats() throws {
        let wrapper = SkyPasteboard()
        let plain = try wrapper.encode(text: "hi", format: .text)
        guard case .plain(let t) = plain.payload else {
            return XCTFail("expected plain payload")
        }
        XCTAssertEqual(t, "hi")

        let md = try wrapper.encode(text: "# Title", format: .md)
        guard case .markdown(let m) = md.payload else {
            return XCTFail("expected markdown payload (goes out as plain text)")
        }
        XCTAssertEqual(m, "# Title")

        let html = try wrapper.encode(text: "<b>hi</b>", format: .html)
        guard case .html(let h) = html.payload else {
            return XCTFail("expected html payload")
        }
        XCTAssertEqual(h, "<b>hi</b>")
    }

    func testWriteAndRestoreRoundTrip() throws {
        let pb = NSPasteboard.general
        let wrapper = SkyPasteboard()

        // Seed a known state and snapshot it.
        pb.clearContents()
        pb.setString("original", forType: .string)
        let snapshot = try wrapper.save()

        // Overwrite the board.
        let data = try wrapper.encode(text: "sneaky", format: .text)
        try wrapper.write(data)
        XCTAssertEqual(pb.string(forType: .string), "sneaky")

        // Restore brings back the original content.
        wrapper.restore(snapshot)
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    func testHTMLWriteCarriesPlainTextFallback() throws {
        let pb = NSPasteboard.general
        let wrapper = SkyPasteboard()
        try wrapper.write(try wrapper.encode(text: "<i>x</i>", format: .html))
        XCTAssertEqual(pb.string(forType: .string), "<i>x</i>")
        XCTAssertNotNil(pb.string(forType: .html))
    }
}

/// CLI flag parsing (pure logic, exercised through OpenSkyKit).
final class CLIFlagsTests: XCTestCase {

    func testFlagExtraction() {
        let flags = SkyFlagParsing.parse(
            ["--element", "7", "--button", "right", "--x", "12.5"]
        )
        XCTAssertEqual(flags.intFlag("element", "--element"), 7)
        XCTAssertEqual(flags.doubleFlag("x", "--x"), 12.5)
        XCTAssertEqual(flags.buttonFlag("button", "--button"), .right)
        XCTAssertNil(flags.intFlag("count", "--count"))
    }
}
