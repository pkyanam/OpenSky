# OpenSky × OpenCode 2 — setup guide (tested)

Everything below was verified end-to-end on opencode 2.0.16 (2026-09-26).

## 1. Install the `opensky` binary
```sh
git clone https://github.com/pkyanam/OpenSky.git
cd OpenSky
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/opensky ~/.local/bin/
```
`~/.local/bin` is already on PATH in this machine's zshrc.

## 2. Install the plugin
The plugin is its own repo: **github.com/pkyanam/opencode-opensky** (private).
```sh
mkdir -p ~/.config/opencode/plugins
curl -fsSL https://raw.githubusercontent.com/pkyanam/opencode-opensky/main/index.ts \
  -o ~/.config/opencode/plugins/opensky.ts
```
Restart OpenCode. It loads on every session (`loading plugin … opensky.ts` in the log).

## 3. Verify
Ask any model: *"List your tools whose names contain opensky."*
You should get 13 tools: list_apps, get_app_state, click, type, press_key, scroll,
drag, paste, set_value, select_text, action, policy, skill.

Then let it drive:
> "Use opensky_list_apps, then get the state of Helium." — real AX tree + screenshot.

## 4. Permissions (first run only)
- **Accessibility**: triggered by the first click/type/press. Approve the terminal app
  that spawned OpenCode.
- **Screen Recording**: triggered by the first screenshot. Approve once.
- The plugin keeps one `opensky` client per OpenCode session; prompts appear at most once each.

## 5. Choosing a model
Verified working: `cloudflare-workers-ai/@cf/zai-org/glm-5.3-flash` (tool round-trips fine).
Known issue: the `belweave` router errors on tool-result round-trips ("upstream model error") —
router-side; text-only prompts on it work. Use any provider that handles `tool_use`/
`tool_result` message pairs correctly.

## 6. What the agent sees
- `opensky_get_app_state` returns the AX tree with `[N]` indices + a screenshot path — the
  model can read elements AND open the PNG for vision.
- Policy denials surface as clean errors (`policyForbidden`, `policyDenied`) with the
  instruction to surface, not retry.
- Lock screen: while the Mac is locked, input actions queue by default and auto-resume
  on unlock (`--when-locked fail|skip` to change).

## 7. Without OpenCode (other harnesses)
- **MCP**: `opensky mcp` — stdio JSON-RPC, 12 tools, same surface (Claude/Cursor/Cline).
- **Raw subprocess**: `opensky --skill` teaches any agent everything.
- **HTTP/JSON-lines**: `opensky serve --json-lines` (roadmap item — v1.0).
