# What to build on OpenSky

OpenSky is the hands layer. These are the applications it unlocks, ordered by
effort-to-value.

## Ship-ready ideas
1. **GUI test runner** (`skytest`) — declarative YAML: open app, wait for element
   [42], click, assert AXValue. Screenshot diffing on failure. Replaces brittle
   AppleScript test suites for native apps.
2. **Accessibility-fixer bot** — audit your own apps' AX trees, report missing
   labels/roles/shortcuts against WCAG + Apple HAT rules. Dev-tool: point it at
   a build, get a report.
3. **Cross-agent benchmark harness** — standardized computer-use tasks
   ("open TextEdit, type X, save to Y") with automatic verification via the AX
   tree; score any model/harness on identical tasks. This is the missing
   piece most CUA papers lack.
4. **Workflow recorder** — watch one human session (listen-only event tap +
   AX snapshots), produce a replayable task script other agents can execute.
5. **Accessibility bridge for motor-impaired users** — voice → LLM → OpenSky:
   "reply to the last message from Sam" as a real, local, screen-level assistive
   layer (privacy-first vs cloud automation).

## Bigger swings
6. **OpenSky Vision add-on** — feed SCK tiles + AX tree as a fused
   representation (pixels + semantics) for models that do better with both.
7. **Multi-Mac orchestration** — openskyd already survives lock/user switch;
   extend to network: one agent driving N Macs over SSH + local openskyd.
8. **iOS bridge** — Accessibility Inspector already reads simulators; a
   `opensky-ios` target could drive apps in Simulator for test automation.

## What we'd add to the core for these
- Element **stability hashes** (re-identify an element across snapshots even
  when indices shift) — unlocks 1, 3, 5.
- `wait`/`poll` primitives (element-appears) — unlocks 1, 4.
- Gesture synthesis (pinch/rotate via CGEvent wheel+custom) — unlocks 8.
