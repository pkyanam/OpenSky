# Parity audit — OpenSky vs the reference Computer-Use surface

Reference = the ChatGPT.app bundled TypeScript definitions
(`targets/mac/client.d.ts` + `types`) and `docs/sky-full-desktop-api.md`.
These are interface documents only; our implementation is independent.

| # | Reference (client.d.ts) | OpenSkyKit | Backend (public API) | Status |
|---|---|---|---|---|
| 1 | `listApps()` → SkyDiscoveredApp[] | `SkyClient.listApps() -> [SkyDiscoveredApp]` | NSWorkspace.runningApplications + /Applications scan | ✅ |
| 2 | `startApp(app)` → MacWindowAppState | `startApp(_:)` | NSRunningApplication.activate() + getAppState | ✅ |
| 3 | `getAppState(app)` → MacWindowAppState {skyshot: text+screenshot} | `getAppState(_:)` (axText + skyshot PNG) | AXUIElement depth-first walk + ScreenCaptureKit | ✅ |
| 4 | `getAppPolicy(app)` → MacAppPolicyResult | `getAppPolicy(_:)` | SkyPolicyStore (UserDefaults) | ✅ |
| 5 | `click({app, clickCount, elementIndex, mouseButton, x, y})` | `click(_:elementIndex:x:y:mouseButton:clickCount:)` | CGEvent mouse, or AXPress by index | ✅ |
| 6 | `drag({app, fromX, fromY, toX, toY})` | `drag(_:fromX:fromY:toX:toY:)` | CGEvent press → moves → release | ✅ |
| 7 | `pressKey({app, key})` | `pressKey(_:key:)` | CGEvent keyboard + SkyKeyMap (X11 keysym chords) | ✅ |
| 8 | `typeText({app, text})` | `typeText(_:text:)` | CGEvent string input | ✅ |
| 9 | `scroll({app, direction, elementIndex, pages, x, y})` | `scroll(_:direction:elementIndex:pages:x:y:)` | CGEvent scroll-wheel | ✅ |
| 10 | `setValue({app, elementIndex, value})` | `setValue(_:elementIndex:value:)` | AX kAXValueAttribute | ✅ |
| 11 | `selectText({app, elementIndex, text, prefix, suffix, selection})` | `selectText(_:elementIndex:text:prefix:suffix:selection:)` | AXSelectedTextRange (UTF-16) | ✅ |
| 12 | `performSecondaryAction({app, elementIndex, action})` | `performSecondaryAction(_:elementIndex:action:)` | AXUIElementPerformAction | ✅ |
| 13 | `paste({app, text, format})` | `paste(_:text:format:)` | NSPasteboard write → Cmd+V → restore | ✅ |
| 14 | `startAudioRecording` / `stopAudioRecording` | — | — | ⏸ v2 (documented gap) |
| 15 | sky `list_windows/activate_window/get_window_state` (full-desktop flavor) | covered by listApps+getAppState (app-scoped model) | — | ✅ semantics preserved |

## Intentional differences
- **In-process by design.** The reference spawns a helper service (`Codex
  Computer Use.app`) and speaks JSON-RPC on a unix socket. We removed that
  hop entirely: one process, zero sockets, no helper to approve or update.
  Same API, fewer moving parts.
- **Element indices are per-snapshot.** The reference resolves indices against
  its own live tree; we resolve against the latest `getAppState` snapshot per
  app (identical model semantics for agent loops: state → act → re-state).
- **Audio recording deferred** (SKY_ENABLE_AUDIO gated in the reference too).

## Added beyond the reference
- `--skill` (agent self-teaching surface), `mcp` server, `serve --json-lines`
  adapter, `help <command>` deep help, structured JSON output mode for every
  command (`--json`), and machine-readable exit codes.
