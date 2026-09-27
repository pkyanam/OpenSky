// opencode-opensky — OpenSky computer-use tools for OpenCode 2 (v2 plugin API).
// Gives any OpenCode agent hands on macOS: see every app, read accessibility
// trees, click, type, drag, scroll, paste — via the `opensky` CLI binary
// (clean-room implementation, 1:1 with ChatGPT/Codex Computer Use).
//
// Shape verified against opencode 2.0.16: default-export {id, setup(ctx)},
// tools registered via ctx.tool.transform(editor => editor.add({...})).
// execute() returns { content: [{type:"text", text}] }.
//
// Requires: the `opensky` binary on PATH (github.com/pkyanam/OpenSky).
// Env override: OPENSKY_BIN=/path/to/opensky
import { execFile } from "child_process"

const BINARY = process.env.OPENSKY_BIN ?? "opensky"

function run(args: string[], timeoutMs = 30_000): Promise<string> {
    return new Promise((resolve) => {
        execFile(BINARY, args, { timeout: timeoutMs, maxBuffer: 32 * 1024 * 1024 }, (err, stdout, stderr) => {
            if (err) {
                const msg = (stderr || stdout || err.message).toString().trim()
                resolve(`ERROR: ${msg}`)
            } else {
                resolve(stdout.toString().trim() || "(ok, no output)")
            }
        })
    })
}

function text(v: string) {
    return { content: [{ type: "text", text: v }] }
}

const APP = {
    type: "object",
    properties: {
        app: {
            type: "string",
            description:
                "Target app: bundle identifier (best, e.g. com.apple.TextEdit), display name (e.g. TextEdit), or pid:N. Call opensky_list_apps first if unsure.",
        },
    },
    required: ["app"],
    additionalProperties: false,
}

function numOrXYSchema() {
    return {
        element_index: { type: "integer", description: "Element index [N] from opensky_get_app_state. Prefer over x/y." },
        x: { type: "number", description: "Window-relative X (use together with y)." },
        y: { type: "number", description: "Window-relative Y (use together with x)." },
    }
}

export default {
    id: "opensky",
    async setup(ctx: any) {
        await ctx.tool.transform((editor: any) => {
            editor.add({
                name: "opensky_list_apps",
                description:
                    "List running and launchable macOS apps (id, bundle id, name, pid, frontmost). " +
                    "Call this FIRST when you don't know an app's identifier. Part of OpenSky computer-use.",
                input: { type: "object", properties: {}, additionalProperties: false },
                async execute() {
                    return text(await run(["list-apps"]))
                },
            })

            editor.add({
                name: "opensky_get_app_state",
                description:
                    "See one macOS app: full accessibility tree with [N] element indices + a screenshot PNG path. " +
                    "CRITICAL: indices are snapshot-scoped — after ANY UI mutation (yours or the app's), call this again " +
                    "before using an index. The state→act→re-state loop is the core OpenSky pattern.",
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        no_screenshot: { type: "boolean", description: "Skip the screenshot (faster). Default false." },
                        disable_diff: { type: "boolean", description: "Force a full AX tree instead of a compact diff from the previous state. Default false (diff, token-efficient)." },
                    },
                    required: ["app"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    const argv = ["state", input.app]
                    if (input.no_screenshot) argv.push("--no-shot")
                    if (input.disable_diff) argv.push("--full")
                    return text(await run(argv, 60_000))
                },
            })

            editor.add({
                name: "opensky_click",
                description:
                    "Click in a macOS app — by element index (PREFERRED, from opensky_get_app_state) or window-relative coordinates. " +
                    "Re-run opensky_get_app_state afterwards: indices move after any UI change.",
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        ...numOrXYSchema(),
                        button: { type: "string", enum: ["left", "right", "middle"], description: "Default left." },
                        count: { type: "integer", description: "Click count: 2 = double-click. Default 1." },
                    },
                    required: ["app"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    const argv = ["click", input.app]
                    if (input.element_index !== undefined) argv.push("--element", String(input.element_index))
                    if (input.x !== undefined && input.y !== undefined) argv.push("--x", String(input.x), "--y", String(input.y))
                    if (input.button) argv.push("--button", input.button)
                    if (input.count) argv.push("--count", String(input.count))
                    return text(await run(argv))
                },
            })

            editor.add({
                name: "opensky_type",
                description:
                    "Type text into the focused element of a macOS app. Click the field (or use opensky_set_value) first. " +
                    "For long text prefer opensky_paste (atomic, faster).",
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        text: { type: "string", description: "Text to type." },
                    },
                    required: ["app", "text"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    return text(await run(["type", input.app, input.text]))
                },
            })

            editor.add({
                name: "opensky_press_key",
                description:
                    'Press a key chord in a macOS app, X11 keysym style: "Return", "Escape", "Tab", "Control_L+a", "Meta_L+v", "Down".',
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        key: { type: "string", description: 'Key chord, e.g. "Control_L+a".' },
                    },
                    required: ["app", "key"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    return text(await run(["press-key", input.app, input.key]))
                },
            })

            editor.add({
                name: "opensky_navigate",
                description:
                    'Navigate a Chromium-based browser (Chrome, Edge, Brave, Helium, Arc) to a URL atomically: focuses the address bar, types the URL, presses Return — one focus activation, focus restored to the user afterwards. ALWAYS prefer this over type/press-key recipes for URLs.',
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        url: { type: "string", description: 'Full URL, e.g. "https://www.youtube.com".' },
                    },
                    required: ["app", "url"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    return text(await run(["navigate", input.app, input.url]))
                },
            })

            editor.add({
                name: "opensky_scroll",
                description: "Scroll a macOS app up/down/left/right by pages, at the window, an element, or coordinates.",
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        direction: { type: "string", enum: ["up", "down", "left", "right"] },
                        pages: { type: "number", description: "Pages to scroll (can be fractional). Default 1." },
                        ...numOrXYSchema(),
                    },
                    required: ["app", "direction"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    const argv = ["scroll", input.app, "--direction", input.direction]
                    if (input.pages !== undefined) argv.push("--pages", String(input.pages))
                    if (input.element_index !== undefined) argv.push("--element", String(input.element_index))
                    if (input.x !== undefined && input.y !== undefined) argv.push("--x", String(input.x), "--y", String(input.y))
                    return text(await run(argv))
                },
            })

            editor.add({
                name: "opensky_drag",
                description: "Drag within a macOS app from window-relative (from_x, from_y) to (to_x, to_y).",
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        from_x: { type: "number" },
                        from_y: { type: "number" },
                        to_x: { type: "number" },
                        to_y: { type: "number" },
                    },
                    required: ["app", "from_x", "from_y", "to_x", "to_y"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    return text(await run([
                        "drag", input.app,
                        "--from-x", String(input.from_x), "--from-y", String(input.from_y),
                        "--to-x", String(input.to_x), "--to-y", String(input.to_y),
                    ]))
                },
            })

            editor.add({
                name: "opensky_paste",
                description:
                    "Paste text into a macOS app via the clipboard (atomic, fast for long text; restores the user's clipboard afterwards).",
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        text: { type: "string" },
                        format: { type: "string", enum: ["text", "md", "html"], description: "Default text." },
                    },
                    required: ["app", "text"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    const argv = ["paste", input.app, "--text", input.text]
                    if (input.format) argv.push("--format", input.format)
                    return text(await run(argv))
                },
            })

            editor.add({
                name: "opensky_set_value",
                description:
                    "Set a macOS element's value directly (form fields, text areas). More reliable than click+type. " +
                    "Get the index from opensky_get_app_state first.",
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        element_index: { type: "integer" },
                        value: { type: "string" },
                    },
                    required: ["app", "element_index", "value"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    return text(await run(["set-value", input.app, "--element", String(input.element_index), "--value", input.value]))
                },
            })

            editor.add({
                name: "opensky_select_text",
                description:
                    "Select text inside a macOS element by needle (optional prefix/suffix to disambiguate). " +
                    "Get the index from opensky_get_app_state first.",
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        element_index: { type: "integer" },
                        text: { type: "string", description: "Text to select." },
                        prefix: { type: "string" },
                        suffix: { type: "string" },
                    },
                    required: ["app", "element_index"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    const argv = ["select-text", input.app, "--element", String(input.element_index)]
                    if (input.text) argv.push("--text", input.text)
                    if (input.prefix) argv.push("--prefix", input.prefix)
                    if (input.suffix) argv.push("--suffix", input.suffix)
                    return text(await run(argv))
                },
            })

            editor.add({
                name: "opensky_action",
                description:
                    "Invoke a named accessibility action on a macOS element (e.g. AXPress, AXRaise, AXConfirm). " +
                    "Available actions are listed per element in opensky_get_app_state output.",
                input: {
                    type: "object",
                    properties: {
                        app: { type: "string", description: "bundle id, display name, or pid:N" },
                        element_index: { type: "integer" },
                        action: { type: "string", description: "AX action name, e.g. AXPress." },
                    },
                    required: ["app", "element_index", "action"],
                    additionalProperties: false,
                },
                async execute(input: any) {
                    return text(await run(["action", input.app, "--element", String(input.element_index), "--action", input.action]))
                },
            })

            editor.add({
                name: "opensky_policy",
                description:
                    "Get the OpenSky approval policy for a macOS app (allowed/denied/forbidden). " +
                    "Forbidden apps are hard-blocked: never retry. Denied high-risk apps need the user's explicit approval.",
                input: APP,
                async execute(input: any) {
                    return text(await run(["policy", input.app]))
                },
            })

            editor.add({
                name: "opensky_skill",
                description:
                    "Print the complete OpenSky operational manual (permissions, the state→act→re-state loop, error taxonomy, rules of engagement). " +
                    "Read this once before your first computer-use action; it prevents the two classic agent failure modes: " +
                    "stale element indices and permission confusion.",
                input: { type: "object", properties: {}, additionalProperties: false },
                async execute() {
                    return text(await run(["--skill"]))
                },
            })
        })
    },
}
