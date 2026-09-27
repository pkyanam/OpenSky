// OpenSky — MCPServer.swift (types fixed)
// Model Context Protocol (stdio transport) server for OpenSky.
// Speaks JSON-RPC 2.0, one message per line (MCP stdio variant used by
// OpenCode / Claude harnesses). Tools mirror the CLI commands 1:1.

import Foundation
import OpenSkyKit

enum MCPServer {
    struct ToolSpec {
        let name: String
        let description: String
        let inputSchema: String  // JSON object literal
    }

    static let tools: [ToolSpec] = [
        ToolSpec(name: "list_apps", description: "List running and launchable macOS apps (id, bundle id, name, pid, frontmost). Call this first when you don't know an app's identifier.",
                 inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
        ToolSpec(name: "get_app_state", description: "See one app: accessibility tree with [N] element indices + a screenshot PNG path. Call after every UI mutation before using an element index again — indices are snapshot-scoped.",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string","description":"bundle id, display name, or pid:N"},"no_screenshot":{"type":"boolean","default":false}},"required":["app"],"additionalProperties":false}"#),
        ToolSpec(name: "click", description: "Click an element by index (preferred) or window-relative coordinates.",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string"},"element_index":{"type":"integer"},"x":{"type":"number"},"y":{"type":"number"},"button":{"type":"string","enum":["left","right","middle"],"default":"left"},"count":{"type":"integer","default":1}},"required":["app"],"additionalProperties":false}"#),
        ToolSpec(name: "type_text", description: "Type text into the focused element of an app. Click or set_value a field first.",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string"},"text":{"type":"string"}},"required":["app","text"],"additionalProperties":false}"#),
        ToolSpec(name: "press_key", description: "Press a key chord, X11 keysym style (e.g. \"Control_L+a\", \"Return\", \"Escape\").",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string"},"key":{"type":"string"}},"required":["app","key"],"additionalProperties":false}"#),
        ToolSpec(name: "drag", description: "Drag from window-relative (fromX,fromY) to (toX,toY).",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string"},"from_x":{"type":"number"},"from_y":{"type":"number"},"to_x":{"type":"number"},"to_y":{"type":"number"}},"required":["app","from_x","from_y","to_x","to_y"],"additionalProperties":false}"#),
        ToolSpec(name: "scroll", description: "Scroll an app up/down/left/right by pages, at an element or coordinates.",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string"},"direction":{"type":"string","enum":["up","down","left","right"]},"pages":{"type":"number","default":1},"element_index":{"type":"integer"},"x":{"type":"number"},"y":{"type":"number"}},"required":["app","direction"],"additionalProperties":false}"#),
        ToolSpec(name: "paste", description: "Paste text via the clipboard (atomic, fast for long text; restores the user's clipboard).",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string"},"text":{"type":"string"},"format":{"type":"string","enum":["text","md","html"],"default":"text"}},"required":["app","text"],"additionalProperties":false}"#),
        ToolSpec(name: "set_value", description: "Set an element's AXValue directly (form fields).",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string"},"element_index":{"type":"integer"},"value":{"type":"string"}},"required":["app","element_index","value"],"additionalProperties":false}"#),
        ToolSpec(name: "select_text", description: "Select text inside an element by needle (and optional prefix/suffix).",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string"},"element_index":{"type":"integer"},"text":{"type":"string"},"prefix":{"type":"string"},"suffix":{"type":"string"}},"required":["app","element_index"],"additionalProperties":false}"#),
        ToolSpec(name: "perform_secondary_action", description: "Invoke a named accessibility action on an element (e.g. AXPress, AXRaise).",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string"},"element_index":{"type":"integer"},"action":{"type":"string"}},"required":["app","element_index","action"],"additionalProperties":false}"#),
        ToolSpec(name: "get_policy", description: "Get the approval policy (allowed/denied/forbidden) for an app.",
                 inputSchema: #"{"type":"object","properties":{"app":{"type":"string"}},"required":["app"],"additionalProperties":false}"#),
    ]

    /// Keep the client alive across calls so permissions prompts persist.
    static let client = SkyMacComputerUseClient(
        options: SkyClientOptions(timeoutSeconds: 30, disableScreenshots: false, screenshotDirectory: nil)
    )

    static func run() async throws {
        let outFD = FileHandle.standardOutput
        // MCP stdio: one JSON-RPC message per line.
        while true {
            guard let line = readLine() else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await send(outFD, .error(id: nil, code: -32700, message: "parse error"))
                continue
            }
            let id = req["id"]
            let method = req["method"] as? String ?? ""

            switch method {
            case "initialize":
                let result: [String: Any] = [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "opensky", "version": "0.9.0"],
                ]
                await send(outFD, .result(id: id, result: result))
            case "notifications/initialized":
                continue // notification: no response
            case "ping":
                await send(outFD, .result(id: id, result: [:]))
            case "tools/list":
                let list = tools.map { t -> [String: Any] in
                    ["name": t.name,
                     "description": t.description,
                     "inputSchema": (try! JSONSerialization.jsonObject(with: Data(t.inputSchema.utf8)))]
                }
                await send(outFD, .result(id: id, result: ["tools": list]))
            case "tools/call":
                let params = req["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                await dispatch(name: name, args: args, id: id, outFD: outFD)
            case let m where m.hasPrefix("notifications/"):
                continue
            default:
                await send(outFD, .error(id: id, code: -32601, message: "method not found: \(method)"))
            }
        }
    }

    // MARK: - Tool dispatch

    static func dispatch(name: String, args: [String: Any], id: Any?, outFD: FileHandle) async {
        do {
            let out: String
            switch name {
            case "list_apps":
                let apps = try await client.listApps()
                out = apps.map { a -> String in
                    "\(a.id)\t\(a.bundleIdentifier ?? "-")\t\(a.displayName ?? "-")\tpid=\(a.pid ?? 0)\(a.isFrontmost ? "\tFRONTMOST" : "")"
                }.joined(separator: "\n")
            case "get_app_state":
                let app = args["app"] as? String ?? ""
                let noShot = args["no_screenshot"] as? Bool ?? false
                let state = try await client.getAppState(app)
                var text = state.skyshot?.text ?? "(no AX tree)"
                if !noShot, let shot = state.skyshot?.screenshot {
                    text += "\n\n[SCREENSHOT] \(shot.url)"
                }
                out = text
            case "click":
                let app = args["app"] as? String ?? ""
                let idx = args["element_index"] as? Int
                let x = args["x"] as? Double, y = args["y"] as? Double
                let button = (args["button"] as? String).flatMap(SkyMouseButton.init(rawValue:)) ?? .left
                let count = args["count"] as? Int ?? 1
                try await client.click(app: app, elementIndex: idx, x: x, y: y, mouseButton: button, clickCount: count)
                out = "ok"
            case "type_text":
                try await client.typeText(app: args["app"] as? String ?? "", text: args["text"] as? String ?? "")
                out = "ok"
            case "press_key":
                try await client.pressKey(app: args["app"] as? String ?? "", key: args["key"] as? String ?? "")
                out = "ok"
            case "drag":
                try await client.drag(app: args["app"] as? String ?? "",
                                      fromX: args["from_x"] as? Double ?? 0, fromY: args["from_y"] as? Double ?? 0,
                                      toX: args["to_x"] as? Double ?? 0, toY: args["to_y"] as? Double ?? 0)
                out = "ok"
            case "scroll":
                let dir = (args["direction"] as? String).flatMap(SkyDirection.init(rawValue:)) ?? .down
                try await client.scroll(app: args["app"] as? String ?? "", direction: dir,
                                        elementIndex: args["element_index"] as? Int,
                                        x: args["x"] as? Double, y: args["y"] as? Double,
                                        pages: args["pages"] as? Double ?? 1)
                out = "ok"
            case "paste":
                let fmt = (args["format"] as? String).flatMap(SkyPasteFormat.init(rawValue:)) ?? .text
                try await client.paste(app: args["app"] as? String ?? "", text: args["text"] as? String ?? "", format: fmt)
                out = "ok"
            case "set_value":
                try await client.setValue(app: args["app"] as? String ?? "",
                                          elementIndex: args["element_index"] as? Int ?? -1,
                                          value: args["value"] as? String ?? "")
                out = "ok"
            case "select_text":
                try await client.selectText(app: args["app"] as? String ?? "",
                                            elementIndex: args["element_index"] as? Int ?? -1,
                                            text: args["text"] as? String ?? "",
                                            prefix: args["prefix"] as? String,
                                            suffix: args["suffix"] as? String)
                out = "ok"
            case "perform_secondary_action":
                try await client.performSecondaryAction(app: args["app"] as? String ?? "",
                                                        elementIndex: args["element_index"] as? Int ?? -1,
                                                        action: args["action"] as? String ?? "AXPress")
                out = "ok"
            case "get_policy":
                let policy = try await client.getAppPolicy(args["app"] as? String ?? "")
                out = "decision=\(policy.decision.rawValue) persistentApproval=\(policy.allowPersistentApproval)"
            default:
                await send(outFD, .error(id: id, code: -32602, message: "unknown tool: \(name)"))
                return
            }
            await send(outFD, .result(id: id, result: [
                "content": [["type": "text", "text": out]],
            ]))
        } catch let err as SkyComputerUseError {
            await send(outFD, .result(id: id, result: [
                "content": [["type": "text", "text": "ERROR \(err.errorName.rawValue): \(err.message)"]],
                "isError": true,
            ]))
        } catch {
            await send(outFD, .result(id: id, result: [
                "content": [["type": "text", "text": "ERROR: \(error.localizedDescription)"]],
                "isError": true,
            ]))
        }
    }

    // MARK: - Framing

    enum Message {
        case result(id: Any?, result: [String: Any])
        case error(id: Any?, code: Int, message: String)
    }

    static func send(_ fd: FileHandle, _ msg: Message) async {
        var obj: [String: Any] = ["jsonrpc": "2.0"]
        switch msg {
        case let .result(id, result):
            if let id { obj["id"] = id }
            obj["result"] = result
        case let .error(id, code, message):
            if let id { obj["id"] = id }
            obj["error"] = ["code": code, "message": message]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        fd.write((line + "\n").data(using: .utf8)!)
    }
}
