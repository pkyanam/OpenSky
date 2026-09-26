# OpenSky

**A clean-room macOS computer-use framework for AI agents — Apple Silicon.**
Give any agent hands: it can see every app, read every window's accessibility
tree, click, type, drag, scroll, and screenshot — through one consistent API,
on-device, on public macOS frameworks.

> Modeled on the ChatGPT desktop app's Computer Use API surface (its bundled
> TypeScript definitions and API docs are the interface spec). Every line of
> implementation is our own, written on public macOS frameworks. MIT licensed.

## What it is (and isn't)

OpenSky is **three things in one repo**:

| Piece | What it is | Who uses it |
|---|---|---|
| **`OpenSkyKit`** | Swift library — the full computer-use engine | Swift/macOS developers embedding agent hands in their app |
| **`opensky` CLI** | A single static binary on your `PATH` | Humans, shell scripts, and every agent harness that can run a subprocess |
| **MCP server** | `opensky mcp` — Model Context Protocol stdio server | Claude Desktop/Code, Cursor, Cline, Codex, any MCP client |

It is **not** a `.app`. It is not a daemon you babysit. It is a library + a
binary + an MCP server that starts on demand and exits when the client exits.

## Install

```sh
git clone https://github.com/pkyanam/OpenSky.git
cd OpenSky && make install        # builds release, drops `opensky` into /usr/local/bin
# or: swift build -c release && sudo cp .build/release/opensky /usr/local/bin/
```

Requirements: Apple Silicon Mac, macOS 14+, Xcode 15+ (to build).
At runtime the binary needs **Accessibility** permission (System Settings →
Privacy & Security → Accessibility) for input/state, and **Screen Recording**
permission for screenshots. It prompts once, on first use.

## The CLI (this is how agents drive it)

```sh
opensky list-apps                 # every launchable/running app
opensky state TextEdit            # AX tree + screenshot for one app
opensky click TextEdit --element 42
opensky click TextEdit --x 300 --y 200
opensky type Safari "hello world"
opensky press-key TextEdit "Control_L+a"
opensky drag Finder --from-x 10 --from-y 10 --to-x 300 --to-y 300
opensky scroll Chrome --direction down --pages 2
opensky paste Notes --text "from clipboard" --format text
opensky set-value TextEdit --element 42 --value "new text"
opensky select-text Notes --element 12 --text "invoice" --prefix "total "
opensky action Finder --element 7 --action AXRaise
opensky policy TextEdit           # show the approval decision for an app
opensky mcp                       # speak MCP over stdio (for agent harnesses)
```

**The life hack:** every agent harness can teach itself OpenSky in one call:

```sh
opensky --skill        # prints a complete agent-grade SKILL.md to stdout
```

`--skill` emits the whole operational manual — command grammar, element-index
semantics, error taxonomy, permissions troubleshooting, do/don't patterns —
formatted so an agent can read it once and operate immediately. Harnesses
should run `opensky --skill > ~/.agent-skills/opensky/SKILL.md` at install.

```sh
opensky --help            # human-grade help, every flag explained
opensky help click        # per-command deep help
```

## API (OpenSkyKit, 1:1 with the reference surface)

```swift
import OpenSkyKit

let sky = SkyClient()

for app in try await sky.listApps() {
    print(app.displayName ?? app.bundleIdentifier ?? "?", app.pid ?? 0)
}

// See an app: full AX tree (stable element indices) + screenshot
let state = try await sky.getAppState("com.apple.TextEdit")
print(state.axText)                      // "[42] AXButton title=Save ..."
print(state.skyshot?.screenshot?.url)    // file:///.../skyshot-....png

// Touch it: the same grammar as the reference implementation
try await sky.click(.app("com.apple.TextEdit"), elementIndex: 42)
try await sky.click(.app("TextEdit"), x: 300, y: 200, clickCount: 2)
try await sky.pressKey("TextEdit", key: "Control_L+a")
try await sky.typeText("TextEdit", text: "Hello")
try await sky.drag(.app("Finder"), fromX: 10, fromY: 10, toX: 300, toY: 300)
try await sky.scroll("Chrome", direction: .down, pages: 2)
try await sky.paste("Notes", text: "…", format: .text)
try await sky.setValue("TextEdit", elementIndex: 42, value: "…")
try await sky.selectText("Notes", elementIndex: 12, text: "invoice")
try await sky.performSecondaryAction("Finder", elementIndex: 7, action: "AXRaise")

// Policy: allow/deny/forbidden per app, persisted, risk-rated
let policy = try await sky.getAppPolicy("com.unknown.app")
// decision: .allowed / .denied / .forbidden, risk: .low / .high
```

Method-for-method parity with the reference `MacComputerUseClient` interface;
see [docs/PARITY.md](docs/PARITY.md) for the mapping table (their method → our
implementation → the public API used).

## MCP (for agent harnesses)

```sh
opensky mcp
```

Speaks Model Context Protocol over stdio. Tools exposed: `list_apps`,
`get_app_state`, `click`, `type_text`, `press_key`, `drag`, `scroll`, `paste`,
`set_value`, `select_text`, `perform_secondary_action`, `get_policy`.
Each tool description is self-contained, so a harness needs zero prior
knowledge. Register with any MCP client:

```json
{ "mcpServers": { "opensky": { "command": "opensky", "args": ["mcp"] } } }
```

**Adapter philosophy.** Harnesses disagree about everything — Claude wants
MCP, Codex has its own tool surface, some run raw shell, some import
libraries. OpenSky meets each at its layer:

| Harness style | How it connects |
|---|---|
| MCP clients (Claude, Cursor, Cline, Zed…) | `opensky mcp` (stdio) |
| Shell-executing agents (Codex CLI, OpenCode, aider, custom) | `opensky …` subprocess + `--skill` for self-teaching |
| Swift apps embedding hands | `import OpenSkyKit` |
| Anything else | JSON-lines mode: `opensky serve --json-lines` (one request per line, one response per line) |

One engine, four doors. The CLI is intentionally the universal adapter:
string-in, string-out, no SDK required.

## Permissions & safety

- First input/state call triggers the **Accessibility** prompt; first
  screenshot triggers **Screen Recording**. Both are one-time per app binary.
- `policy` implements a per-app approval store: new apps default to
  **allowed/low-risk** for *read* (state) and require explicit approval for
  *high-risk* write actions (typing, pasting, set-value) — matching the
  reference `decision/risk/allowPersistentApproval` model.
- Nothing leaves the machine. No telemetry, no network. Ever.

## Performance

- Cold `list-apps`: ~15 ms. `state` on a 350-element tree: ~250 ms including
  a full-resolution window screenshot.
- Screenshots stream from **ScreenCaptureKit** (hardware compositor path) —
  no CGWindowList legacy API (dead on macOS 15+).
- The AX walker iterates lazily and releases element handles eagerly; a full
  tree snapshot is a value type — flat, copy-on-write, ~0 allocations steady
  state per element.
- Binary is static-linked where possible; ~4 MB, no external runtime deps.

## Repository layout

```
Sources/OpenSkyKit/     the engine
  Core.swift            types: AppIdentifier, ElementIndex, errors
  AppResolver.swift     NSWorkspace app discovery (listApps)
  AXWalker.swift        AXUIElement depth-first walk → indexed, stable nodes
  AXActions.swift       AX-level actions (set-value, select-text, secondary)
  Events.swift          CGEvent synthesis: click/drag/scroll/press/type
  Pasteboard.swift      paste pipeline (NSPasteboard + AX paste routing)
  Screenshot.swift      ScreenCaptureKit window capture
  Policy.swift          per-app approval store (decision/risk/persistent)
  Client.swift          the SkyClient facade (1:1 reference API)
  FlagParsing.swift     CLI arg grammar (shared by CLI + MCP layers)
Sources/OpenSkyCLI/     the `opensky` binary (main + CLI + MCP + --skill)
Tests/OpenSkyKitTests/  unit + integration tests (no ChatGPT.app needed)
docs/                   PARITY.md · MCP.md · AGENT-SKILL.md · ARCHITECTURE.md
```

## Docs

- [docs/PARITY.md](docs/PARITY.md) — 1:1 feature parity audit vs the reference
- [docs/MCP.md](docs/MCP.md) — MCP server: tools, schemas, client registration
- [docs/AGENT-SKILL.md](docs/AGENT-SKILL.md) — what `--skill` prints, and why
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — engine internals, perf notes

## Credits & license

Interface inspired by the ChatGPT desktop app's Computer Use API (OpenAI).
This project is an independent clean-room implementation on public macOS
frameworks and is not affiliated with or endorsed by OpenAI. MIT — see
[LICENSE](LICENSE).
