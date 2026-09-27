# OpenSky

**A clean-room macOS computer-use framework for AI agents — Apple Silicon.**
Give any agent hands: it can see every running app, read every window's accessibility
tree, click, type, drag, scroll, and screenshot — through one consistent API,
entirely on-device, built on public macOS frameworks. No daemon. No accounts. No telemetry.

> Modeled on the ChatGPT desktop app's Computer Use API surface (its bundled
> TypeScript definitions and API docs serve as the interface spec). Every line of
> implementation is our own, written on public macOS frameworks. MIT licensed.

## One-line install

```sh
curl -fsSL https://raw.githubusercontent.com/pkyanam/OpenSky/main/scripts/install.sh | bash
```

The installer is **idempotent**: run it again any time to upgrade in place. It
- puts the `opensky` binary in `~/.local/bin` (added to PATH for you, once),
- installs the **OpenCode 2 plugin** automatically when OpenCode is present (set `OPENSKY_NO_PLUGIN=1` to skip),
- swaps the binary atomically — a failed install never breaks an existing one.

Prefer no pipe-to-bash? Two-liner:

```sh
git clone https://github.com/pkyanam/OpenSky && cd OpenSky
bash scripts/install.sh
```

Requirements: Apple Silicon Mac, macOS 14+. Source builds need Xcode Command
Line Tools (`xcode-select --install`); the release download path does not.

At runtime, the first input command prompts for **Accessibility** permission and
the first screenshot prompts for **Screen Recording** — both one-time per binary.

## Try it (30 seconds)

```sh
opensky list-apps                      # every running/launchable app
opensky state com.apple.TextEdit       # AX tree with [N] element indices + screenshot path
opensky click TextEdit --element 42    # click an element
opensky type TextEdit "hello world"    # type text
```

## For agents (this is the important part)

Any harness that can run a subprocess can adopt OpenSky in one call:

```sh
opensky --skill        # prints the complete agent-grade operational manual
```

`--skill` covers command grammar, the **state → act → re-state** loop (element
indices are snapshot-scoped — the #1 agent failure mode), app identifier forms,
the stable error taxonomy, permissions troubleshooting, and do/don't rules.
Have your agent run it once and save the output as a skill file.

MCP clients (Claude Desktop, Cursor, Cline, Zed…):

```json
{ "mcpServers": { "opensky": { "command": "opensky", "args": ["mcp"] } } }
```

**OpenCode 2** users: the installer drops in a native plugin with 13 tools.
Verify by asking your model: *"List your tools whose names contain opensky."*

## Staying up to date

```sh
opensky update            # check + update (aliases: --check | --install)
```

Self-update pulls the latest GitHub release for your architecture and swaps the
binary atomically in-place (same location, no sudo). No release asset? It
builds from source automatically (requires Xcode CLT). Re-running the one-line
installer also upgrades cleanly.

## Commands

```
opensky list-apps                 # running + launchable apps (id/bundle/pid/frontmost)
opensky state <app>               # AX tree with [N] indices + screenshot PNG path
opensky click <app> (--element N | --x N --y N) [--button b] [--count n]
opensky type <app> "text"
opensky press-key <app> "Control_L+a"     # X11 keysym chords
opensky drag <app> --from-x N --from-y N --to-x N --to-y N
opensky scroll <app> --direction down [--pages N] [--x N --y N | --element N]
opensky paste <app> --text T [--format text|md|html]
opensky set-value <app> --element N --value V
opensky select-text <app> --element N --text T [--prefix P] [--suffix S]
opensky action <app> --element N --action AXPress
opensky policy <app>              # per-app approval decision
opensky mcp                       # MCP stdio server for agent harnesses
opensky --skill                   # the agent manual
opensky version / update          # version + self-update
```

App identifiers: bundle id (`com.apple.TextEdit`) → display name (`TextEdit`) → `pid:1234`.

## Safety model

- **Policy engine**: system-critical apps (Finder, loginwindow, System Settings,
  keychain, screencapture helpers) are **forbidden** — hard-blocked, never
  overridable. High-risk apps (Mail, Messages…) require explicit approval for
  writes. Every decision is queryable: `opensky policy <app>`.
- **Lock-screen behavior**: while the Mac is locked, input actions are
  hard-paused and queue by default, auto-resuming on unlock
  (`--when-locked queue|fail|skip`). OpenSky never injects input into the
  loginwindow and never records keystroke content. See
  [docs/LOCK-SCREEN.md](docs/LOCK-SCREEN.md).
- **Local-only**: no network calls except `opensky update` (GitHub releases).
  No telemetry. Ever.

## Performance

- Cold `list-apps`: ~15 ms · full `state` (350-element tree + screenshot): ~250 ms
- Screenshots via **ScreenCaptureKit** (hardware path; legacy APIs are dead on macOS 15+)
- Static-ish binary (~600 KB), zero runtime dependencies, zero external services

## Using it as a library

```swift
import OpenSkyKit

let sky = SkyClient()
for app in try await sky.listApps() { print(app.id) }

let state = try await sky.getAppState("com.apple.TextEdit")
print(state.skyshot?.text)                  // AX tree with [N] indices
try await sky.click(app: "com.apple.TextEdit", elementIndex: 42)
try await sky.typeText(app: "TextEdit", text: "Hello")
```

Method-for-method parity with the reference surface —
[docs/PARITY.md](docs/PARITY.md) has the full mapping table.

## Repository layout

```
Sources/OpenSkyKit/      the engine (AX walker, CGEvent synthesis, SCK capture, policy)
Sources/OpenSkyCLI/      the opensky binary (CLI + MCP + --skill + self-update)
Tests/OpenSkyKitTests/   unit + integration tests (23; no external apps required)
scripts/install.sh       the one-line installer (idempotent)
plugin/opensky.ts        OpenCode 2 plugin (also installed by the installer)
docs/                    PARITY · MCP · AGENT-SKILL · LOCK-SCREEN · OPENCODE · APPLICATIONS
```

## Docs

- [docs/OPENCODE.md](docs/OPENCODE.md) — tested OpenCode 2 setup guide
- [docs/MCP.md](docs/MCP.md) — MCP tools, schemas, error model
- [docs/AGENT-SKILL.md](docs/AGENT-SKILL.md) — what `--skill` prints and why
- [docs/LOCK-SCREEN.md](docs/LOCK-SCREEN.md) — lock-screen design (verified against the reference)
- [docs/PARITY.md](docs/PARITY.md) — 1:1 feature parity audit vs the reference
- [docs/APPLICATIONS.md](docs/APPLICATIONS.md) — what to build on OpenSky

## Credits & license

Interface inspired by the ChatGPT desktop app's Computer Use API (OpenAI).
Independent clean-room implementation on public macOS frameworks; not
affiliated with or endorsed by OpenAI. MIT — see [LICENSE](LICENSE).
