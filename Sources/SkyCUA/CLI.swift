import Foundation
import SkyCUALib

/// sky-cua demo CLI.
/// Usage:
///   sky-cua list-apps
///   sky-cua state <app> [--no-shot] [--out DIR]
///   sky-cua click <app> --x N --y N | --element N [--button left|right|middle] [--count N]
///   sky-cua press-key <app> "Control_L+a"
///   sky-cua type <app> "text"
///   sky-cua set-value <app> --element N --value "text"
///   sky-cua select-text <app> --element N --text "needle" [--prefix P] [--suffix S]
///   sky-cua action <app> --element N --action AXPress
///   sky-cua drag <app> --from-x N --from-y N --to-x N --to-y N
///   sky-cua scroll <app> --direction down [--pages 1] [--x N --y N | --element N]
///   sky-cua paste <app> --text "content" [--format text|md|html]
///   sky-cua policy <app>

enum SkyCUACommandLine {
    static let client = SkyMacComputerUseClient(
        options: SkyClientOptions(
            timeoutSeconds: 30,
            disableScreenshots: false,
            screenshotDirectory: nil
        )
    )

    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            print(usage)
            exit(2)
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "list-apps":
                try await listApps()
            case "state":
                try await state(rest)
            case "click":
                try await click(rest)
            case "press-key":
                try await pressKey(rest)
            case "type":
                try await typeText(rest)
            case "set-value":
                try await setValue(rest)
            case "select-text":
                try await selectText(rest)
            case "action":
                try await action(rest)
            case "drag":
                try await drag(rest)
            case "scroll":
                try await scroll(rest)
            case "paste":
                try await paste(rest)
            case "policy":
                try await policy(rest)
            case "help", "--help", "-h":
                print(usage)
            default:
                FileHandle.standardError.write("unknown command '\(command)'\n\n\(usage)".data(using: .utf8)!)
                exit(2)
            }
        } catch let error as SkyComputerUseError {
            FileHandle.standardError.write("ERROR \(error)\n".data(using: .utf8)!)
            exit(1)
        } catch {
            FileHandle.standardError.write("ERROR \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // MARK: - Commands

    static func listApps() async throws {
        let apps = client.listApps()
        print("id\tname\trunning\tfrontmost\tpath")
        for app in apps {
            let path = app.appPath ?? "-"
            print(
                "\(app.id)\t\(app.displayName ?? "-")\t\(app.isRunning ? "yes" : "no")\t\(app.isFrontmost ? "yes" : "no")\t\(path)"
            )
        }
        print("total=\(apps.count)")
    }

    static func state(_ args: [String]) async throws {
        guard let app = args.first else { throw usageError("state <app>") }
        var noShot = false
        var outDir: URL? = nil
        var iter = args.dropFirst().makeIterator()
        while let flag = iter.next() {
            switch flag {
            case "--no-shot": noShot = true
            case "--out": outDir = URL(fileURLWithPath: iter.next() ?? ".")
            default: break
            }
        }
        let probe = SkyMacComputerUseClient(
            options: SkyClientOptions(
                timeoutSeconds: 30,
                disableScreenshots: noShot,
                screenshotDirectory: outDir
            )
        )
        let result = try await probe.getAppState(app)
        print("app=\(result.app)")
        if let instructions = result.appSpecificInstructions {
            print("instructions=\(instructions)")
        }
        if let shot = result.skyshot?.screenshot {
            print("screenshot=\(shot.url.prefix(80))...")
        }
        print("--- ax text ---")
        print(result.skyshot?.text ?? "<no text>")
    }

    static func click(_ args: [String]) async throws {
        guard let app = args.first else { throw usageError("click <app> ...") }
        var opts = try parseFlags(Array(args.dropFirst()))
        try await client.click(
            app: app,
            elementIndex: opts.intFlag("element", "--element"),
            x: opts.doubleFlag("x", "--x"),
            y: opts.doubleFlag("y", "--y"),
            mouseButton: opts.buttonFlag("button", "--button") ?? .left,
            clickCount: opts.intFlag("count", "--count") ?? 1
        )
        print("click ok")
    }

    static func pressKey(_ args: [String]) async throws {
        guard let app = args.first, args.count >= 2 else {
            throw usageError("press-key <app> \"Control_L+a\"")
        }
        try await client.pressKey(app: app, key: args[1])
        print("press-key ok")
    }

    static func typeText(_ args: [String]) async throws {
        guard let app = args.first, args.count >= 2 else {
            throw usageError("type <app> \"text\"")
        }
        try await client.typeText(app: app, text: args[1])
        print("type ok")
    }

    static func setValue(_ args: [String]) async throws {
        guard let app = args.first else { throw usageError("set-value <app> --element N --value V") }
        let opts = try parseFlags(Array(args.dropFirst()))
        guard let element = opts.intFlag("element", "--element"),
              let value = opts.stringFlag("value", "--value")
        else { throw usageError("set-value requires --element and --value") }
        try await client.setValue(app: app, elementIndex: element, value: value)
        print("set-value ok")
    }

    static func selectText(_ args: [String]) async throws {
        guard let app = args.first else { throw usageError("select-text <app> --element N --text T") }
        let opts = try parseFlags(Array(args.dropFirst()))
        guard let element = opts.intFlag("element", "--element"),
              let text = opts.stringFlag("text", "--text")
        else { throw usageError("select-text requires --element and --text") }
        let selection: SkySelectionType
        switch opts.stringFlag("selection", "--selection") {
        case "cursor_before": selection = .cursorBefore
        case "cursor_after": selection = .cursorAfter
        default: selection = .text
        }
        try await client.selectText(
            app: app,
            elementIndex: element,
            text: text,
            prefix: opts.stringFlag("prefix", "--prefix"),
            suffix: opts.stringFlag("suffix", "--suffix"),
            selection: selection
        )
        print("select-text ok")
    }

    static func action(_ args: [String]) async throws {
        guard let app = args.first else { throw usageError("action <app> --element N --action AXPress") }
        let opts = try parseFlags(Array(args.dropFirst()))
        guard let element = opts.intFlag("element", "--element"),
              let action = opts.stringFlag("action", "--action")
        else { throw usageError("action requires --element and --action") }
        try await client.performSecondaryAction(app: app, elementIndex: element, action: action)
        print("action ok")
    }

    static func drag(_ args: [String]) async throws {
        guard let app = args.first else { throw usageError("drag <app> --from-x N --from-y N --to-x N --to-y N") }
        let opts = try parseFlags(Array(args.dropFirst()))
        guard let fx = opts.doubleFlag("from-x", "--from-x"),
              let fy = opts.doubleFlag("from-y", "--from-y"),
              let tx = opts.doubleFlag("to-x", "--to-x"),
              let ty = opts.doubleFlag("to-y", "--to-y")
        else { throw usageError("drag requires --from-x/--from-y/--to-x/--to-y") }
        try await client.drag(app: app, fromX: fx, fromY: fy, toX: tx, toY: ty)
        print("drag ok")
    }

    static func scroll(_ args: [String]) async throws {
        guard let app = args.first else { throw usageError("scroll <app> --direction down") }
        let opts = try parseFlags(Array(args.dropFirst()))
        let direction: SkyDirection
        switch opts.stringFlag("direction", "--direction")?.lowercased() {
        case "up", "u": direction = .up
        case "left", "l": direction = .left
        case "right", "r": direction = .right
        default: direction = .down
        }
        try await client.scroll(
            app: app,
            direction: direction,
            elementIndex: opts.intFlag("element", "--element"),
            x: opts.doubleFlag("x", "--x"),
            y: opts.doubleFlag("y", "--y"),
            pages: opts.doubleFlag("pages", "--pages") ?? 1
        )
        print("scroll ok")
    }

    static func paste(_ args: [String]) async throws {
        guard let app = args.first else { throw usageError("paste <app> --text T [--format text|md|html]") }
        let opts = try parseFlags(Array(args.dropFirst()))
        guard let text = opts.stringFlag("text", "--text") else {
            throw usageError("paste requires --text")
        }
        let format: SkyPasteFormat
        switch opts.stringFlag("format", "--format") {
        case "md": format = .md
        case "html": format = .html
        default: format = .text
        }
        try await client.paste(app: app, text: text, format: format)
        print("paste ok")
    }

    static func policy(_ args: [String]) async throws {
        guard let app = args.first else { throw usageError("policy <app>") }
        let result = try await client.getAppPolicy(app)
        print("decision=\(result.decision.rawValue)")
        print("risk=\(result.target.risk.rawValue)")
        print("allowPersistentApproval=\(result.allowPersistentApproval)")
        print("bundleID=\(result.target.bundleIdentifier)")
        print("displayName=\(result.target.displayName)")
    }

    // MARK: - Flag parsing

    typealias Flags = SkyFlags

    static func parseFlags(_ args: [String]) throws -> Flags {
        SkyFlags(raw: args)
    }

    static func usageError(_ text: String) -> SkyComputerUseError {
        SkyComputerUseError(
            code: 0,
            errorName: .invalidApp,
            message: "usage: \(text)",
            requestType: "cli"
        )
    }

    static let usage: String = """
    sky-cua — SkyCUA demo CLI (clean-room macOS computer-use)

    commands:
      list-apps
      state <app> [--no-shot] [--out DIR]
      click <app> (--element N | --x N --y N) [--button left|right|middle] [--count N]
      press-key <app> "Control_L+a"
      type <app> "text"
      set-value <app> --element N --value V
      select-text <app> --element N --text T [--prefix P] [--suffix S]
      action <app> --element N --action AXPress
      drag <app> --from-x N --from-y N --to-x N --to-y N
      scroll <app> --direction down [--pages 1] [--x N --y N | --element N]
      paste <app> --text T [--format text|md|html]
      policy <app>
      help

    app identifiers: bundle id (com.apple.TextEdit), display name (TextEdit), or pid:N
    """
}
