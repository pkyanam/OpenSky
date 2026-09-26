# OpenSky MCP server

`opensky mcp` speaks the Model Context Protocol (stdio transport). Point any
MCP client at it:

```json
{ "mcpServers": { "opensky": { "command": "opensky", "args": ["mcp"] } } }
```

## Tools

Every tool is self-describing; harnesses need zero prior OpenSky knowledge.

| Tool | Input | Returns |
|---|---|---|
| `list_apps` | — | running+launchable apps (id, name, pid, frontmost) |
| `get_app_state` | app (bundle/name/pid), include_screenshot | AX tree text with `[N]` element indices + screenshot path |
| `click` | app, element_index OR x/y, button, count | ok / structured error |
| `type_text` | app, text | ok |
| `press_key` | app, key chord ("Control_L+a") | ok |
| `drag` | app, from_x/y, to_x/y | ok |
| `scroll` | app, direction, pages, element/x/y | ok |
| `paste` | app, text, format | ok |
| `set_value` | app, element_index, value | ok |
| `select_text` | app, element_index, text, prefix?, suffix? | ok |
| `perform_secondary_action` | app, element_index, action | ok |
| `get_policy` | app | decision (allowed/denied/forbidden), risk, allowPersistentApproval |

## Error model (agents: read this)

Errors are returned as MCP tool errors with a stable `code`:
- `permission/accessibility` — grant Accessibility, retry
- `permission/screencapture` — grant Screen Recording, retry
- `policy/denied` / `policy/forbidden` — app blocked; do not retry
- `element/out-of-range` — indices moved; call `get_app_state` again
- `app/not-found` — bad identifier; call `list_apps` first
- `app/not-running` — call `start_app`-equivalent (`list_apps` then retry)

## Sessions

Stateless by design: every tool call resolves the app fresh (fast, ~ms), so
harnesses that interleave other tools between calls never hold stale state —
except element indices, which must be refreshed via `get_app_state` after any
UI mutation (documented in every tool description that takes an index).
