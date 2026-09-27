// OpenSky — AgentSkill.swift
// `opensky --skill` prints this agent-grade manual to stdout.
// Canonical text also lives at docs/AGENT-SKILL.md (keep in sync).

import Foundation

enum AgentSkill {
    static let markdown: String = """
    # OpenSky — Agent Skill

    You can control a macOS computer with the `opensky` CLI. One binary, no
    daemon. Every command returns text; screenshots are saved as PNG files.

    ## First-run permissions
    The FIRST input command (click/type/press-key/...) triggers the macOS
    **Accessibility** permission prompt; the FIRST `state` command with a
    screenshot triggers **Screen Recording**. A human must approve both once
    (System Settings → Privacy & Security). If a command fails with
    `permissionsNotGranted` / `permissionsPending`, do NOT retry blindly —
    tell the user to approve, then retry once.

    ## The core loop (memorize this)
    1. `opensky list-apps` — find the app (bundle id, name, or pid:N).
    2. `opensky state <app>` — see its windows: the AX tree with `[N]`
       element indices + a screenshot path. By default the SECOND and later
       state calls return a COMPACT DIFF from the previous tree (removed/
       added/changed only) — pass `--full` when you need the complete tree
       again (e.g. after losing track). First call is always full.
    3. Act with an index or coordinates: `opensky click <app> --element 42`.
    4. **Re-state.** Element indices are snapshot-scoped. After ANY UI
       mutation (your action or the app's), call `state` again before the
       next indexed action. Stale indices are the #1 failure mode.

    ## Command grammar
    ```
    opensky list-apps
    opensky state <app> [--no-shot] [--out DIR]
    opensky click <app> (--element N | --x N --y N) [--button left|right|middle] [--count N]
    opensky press-key <app> "Control_L+a"     # X11 keysym chords
    opensky type <app> "text"
    opensky set-value <app> --element N --value "text"     # for text fields
    opensky select-text <app> --element N --text "needle" [--prefix P] [--suffix S]
    opensky action <app> --element N --action AXPress       # any AX action name
    opensky drag <app> --from-x N --from-y N --to-x N --to-y N
    opensky scroll <app> --direction up|down|left|right [--pages N] [--x N --y N | --element N]
    opensky paste <app> --text "content" [--format text|md|html]
    opensky policy <app>                      # approval decision for the app
    ```

    ## Choosing an app identifier
    Bundle id is most stable (`net.imput.helium`), display name next
    (`Helium`), `pid:1234` last. If ambiguous → error lists candidates; pick
    the exact one. App not running → `list-apps` to confirm; `state` on a
    launchable app activates it first.

    ## Error taxonomy (stable names — branch on these)
    - `permissionsNotGranted` / `permissionsPending` — ask the human to
      approve Accessibility (input) or Screen Recording (screenshots).
    - `policyDenied` — the app needs explicit high-risk approval; surface to
      the user, don't hammer.
    - `policyForbidden` — hard-blocked; never retry.
    - `screenLocked` — session locked. Default behavior queued the action
      until unlock. `--when-locked fail|skip` changes this. Never try to
      drive the loginwindow; OpenSky refuses by design.
    - `elementNotFound` / `element-out-of-range` — indices moved; re-run
      `state`.
    - `ambiguousApp` / `runningApplicationNotFound` — fix the identifier.

    ## Rules of engagement
    - PREFER element clicks (`--element`) over coordinates; coordinates
      break on layout shifts.
    - The AX tree text is YOUR interface. Screenshots are for the human or a
      vision model, not for guessing indices.
    - Typing into a field: `click` it (or set-value), then `type`. For form
      fields prefer `set-value` when the field exposes AXValue.
    - `paste` is atomic and faster than `type` for long text.
    - Never `--when-locked fail` unless the user asked for fail-fast.
    - Add `--json` to any command for machine-readable output.
    - Destructive actions (delete, send, pay): state the consequence, get
      explicit human confirmation first. OpenSky is hands, not judgment.

    ## MCP mode
    If your harness speaks Model Context Protocol, register:
    `opensky mcp` (stdio). Tool names mirror the CLI commands.
    """
}
