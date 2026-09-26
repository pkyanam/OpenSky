# `opensky --skill` — the agent self-teaching surface

One command prints the complete operational manual to stdout:

```sh
opensky --skill > ~/.agent-skills/opensky/SKILL.md
```

What it contains, in reading order for an agent:
1. **What OpenSky is** (3 sentences) and the permission preconditions.
2. **Command grammar** — every command + flags with copy-paste examples.
3. **The element-index loop** — the core agent pattern:
   `state → pick index → act → re-state`. Indices are snapshot-scoped; never
   reuse an index after a UI mutation.
4. **App identifier forms** — bundle id, display name, `pid:N`; when in doubt
   `list-apps` first.
5. **Error taxonomy** — the six stable error codes above and what to do for
   each (the same table as docs/MCP.md).
6. **Policy** — how allow/deny/forbidden works, that forbidden never
   overridable, and that denied high-risk apps need explicit approval.
7. **Do/don't** — prefer AX element clicks over coordinates; never guess
   indices; screenshots are for humans/vision, the AX text is for you; always
   re-state before re-acting.
8. **JSON output** — `--json` on any command for structured parsing.

Why a flag instead of a website: agents can't always fetch URLs, but every
harness can run a subprocess. `--skill` makes OpenSky teachable by the tool
itself — the installer IS the tutorial. This mirrors the CLI-driven
self-documentation pattern harnesses already trust (man pages, --help) but
written for model consumption, with the exact operational rules an agent
needs to avoid its two classic failure modes: stale indices and permission
confusion.

The same content ships in-repo at docs/AGENT-SKILL.md (this file is the
canonical text; `--skill` prints exactly it).
