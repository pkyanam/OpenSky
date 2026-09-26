# SkyCUA

Clean-room macOS computer-use framework (Apple Silicon, Swift 6.4 / SwiftPM).

The ChatGPT desktop app ships a "Computer Use" feature whose native runtime is
closed-source. SkyCUA re-implements the same **client API surface** as a
standalone SwiftPM framework using **public macOS frameworks only**. The
app's TypeScript interface definitions (`.d.ts`) and bundled API docs were
used as the **interface specification only** — no OpenAI JS/Swift code was
copied, no OpenAI binary is linked, no OpenAI-owned file is redistributed.
Every line here is written from scratch on public APIs.

## Package layout

| Target | Contents |
|---|---|
| `SkyCUALib` (library) | Client, AX walker, input synthesis, policy store, screenshots |
| `SkyCUA` (executable) | `sky-cua` demo CLI |
| `SkyCUATests` | XCTest suite (no ChatGPT.app dependency) |

## Public API (mirrors MacComputerUseClient)

| Their method (client.d.ts) | SkyCUA | Backed by |
|---|---|---|
| `listApps()` | `SkyMacComputerUseClient.listApps() -> [SkyDiscoveredApp]` | `NSWorkspace.runningApplications` + `/Applications` scan |
| `getAppState(app)` | `getAppState(_:) -> SkyWindowAppState` | AXUIElement walk (`AXUIElementCopyAttributeValue`, depth-first stable indices) + ScreenCaptureKit window PNG |
| `getAppPolicy(app)` | `getAppPolicy(_:) -> SkyAppPolicyResult` | UserDefaults-backed `SkyPolicyStore` |
| `startApp(app)` | `startApp(_:)` | `NSRunningApplication.activate()` + `getAppState` |
| `click(...)` | `click(app:elementIndex:x:y:mouseButton:clickCount:)` | `CGEvent` mouse down/up (or AX press path by index) |
| `drag(...)` | `drag(app:fromX:fromY:toX:toY:)` | CGEvent press → interpolated moves → release |
| `pressKey({key})` | `pressKey(app:key:)` | CGEvent keyboard with X11-keysym chord parsing (`SkyKeyMap`) |
| `typeText({text})` | `typeText(app:text:)` | CGEvent Unicode-string keyboard events |
| `scroll(...)` | `scroll(app:direction:elementIndex:x:y:pages:)` | CGEvent scroll-wheel events |
| `setValue(...)` | `setValue(app:elementIndex:value:)` | `AXUIElementSetAttributeValue(kAXValueAttribute)` |
| `selectText(...)` | `selectText(app:elementIndex:text:prefix:suffix:selection:)` | `AXSelectedTextRange` (UTF-16 offsets) |
| `performSecondaryAction(...)` | `performSecondaryAction(app:elementIndex:action:)` | `AXUIElementPerformAction` |
| `paste({text, format})` | `paste(app:text:format:)` | NSPasteboard save → write → `Cmd+V` → restore |
| `startApp` instructions | `appSpecificInstructions` on first `getAppState` | in-client once-per-app set |

Audio recording (`startAudioRecording`/`stopAudioRecording`) is **out of scope
for v1** and deliberately absent.

## Element indexing

`getAppState` walks the AX tree depth-first from the focused (or first)
window, numbering nodes `0..N-1` in visit order — the "element index" the
model references in `click`/`setValue`/`selectText`/`performSecondaryAction`.
Indices are stable within a snapshot; every action resolves against the
**latest** snapshot for that app (per-app cache inside the client). The
serialized text embeds `[N]` markers per element:

```
app=com.apple.TextEdit window=untitled elements=26
[0] AXWindow frame=(0,0,900x600)
[1] AXButton title=OK frame=(20,560,64x24) actions=(AXPress)
[2] AXTextField value=hello editable
```

## Policy model

`SkyAppPolicyResult` mirrors the spec's `MacAppPolicyResult`:
`{ allowPersistentApproval, decision: allowed|denied|forbidden,
target: {appPath, bundleIdentifier, displayName, risk: high|low,
warningSubtitle} }`.

- `forbidden` — safety block list (Finder, Dock, System Settings, security
  agents...): never automatable, not overridable.
- `denied` — explicit org-style block list.
- `allowed` — low-risk default, or a stored approval.
- Default-deny-high-risk: unapproved high-risk apps (Mail, Messages,
  FaceTime, App Store...) return `denied` until explicitly approved via
  `SkyPolicyStore.approve(bundleID:persistent:)`; `allowPersistentApproval`
  governs whether an "always" grant may persist in UserDefaults.

## CLI

```
sky-cua list-apps
sky-cua state <app> [--no-shot] [--out DIR]
sky-cua click <app> (--element N | --x N --y N) [--button left|right|middle] [--count N]
sky-cua press-key <app> "Control_L+a"
sky-cua type <app> "text"
sky-cua set-value <app> --element N --value V
sky-cua select-text <app> --element N --text T [--prefix P] [--suffix S]
sky-cua action <app> --element N --action AXPress
sky-cua drag <app> --from-x N --from-y N --to-x N --to-y N
sky-cua scroll <app> --direction down [--pages 1] [--x N --y N | --element N]
sky-cua paste <app> --text T [--format text|md|html]
sky-cua policy <app>
```

App identifiers: bundle id (`com.apple.TextEdit`), display name (`TextEdit`),
or `pid:N`.

### Verified live (2026-09-26, arm64, macOS 26.6.2)

- `swift build` — clean.
- `sky-cua list-apps` — 26 apps discovered (Finder, Tailscale, Helium, Discord, cmux…).
- `sky-cua state net.imput.helium` — 347-element AX tree with frames, actions,
  editable flags, plus a real ScreenCaptureKit PNG screenshot.
- `swift test` — all green (see Tests).

## Tests

`swift test` runs 23 tests, 0 failures:
- policy decisions (low/high risk, forbidden block list, deny/revoke/approve)
- element-index stability and depth-first ordering (stub-node fixtures, no
  window server required)
- serialized skyshot text format (index markers, editable flags)
- key-chord parsing (X11 keysyms, aliases, malformed-chord rejection)
- pasteboard encode/write/restore round-trip
- CLI flag parsing

Four additional tests exercise a real NSWindow AX fixture in-process
(depth-first walk of live AXUIElement nodes) and skip gracefully — with a
diagnostic reason — on runners where self-process AX reads are structurally
unavailable (`kAXErrorCannotComplete` under headless CLI sessions). No
ChatGPT.app required by any test.

## License

MIT — see [LICENSE](LICENSE).
