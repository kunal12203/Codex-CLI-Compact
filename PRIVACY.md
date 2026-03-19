# Privacy & Telemetry

Dual-Graph respects your privacy. All network calls beyond package installation
are **opt-in** and **off by default**.

## Environment Variables

| Variable | Default | Effect |
|---|---|---|
| `DG_TELEMETRY=1` | off | Enables error reporting and one-time feedback form |
| `DG_AUTO_UPDATE=1` | off | Enables launcher self-update from GitHub/R2 |

You can also pass `--no-update` to `dg`/`dgc` to suppress auto-update for a
single invocation.

## What each flag controls

### `DG_TELEMETRY=1`
- Error reports POST to a Google Apps Script webhook (script step + error message)
- One-time feedback rating POST (asked once, 2+ days after install)
- No machine IDs or hardware identifiers are included

### `DG_AUTO_UPDATE=1`
- Version check: fetches `version.txt` from GitHub/R2 (~100 bytes)
- If newer version exists: downloads `dual_graph_launch.sh` and upgrades `graperoot` via pip
- Re-execs the launcher after update

## What is NOT collected
- No machine IDs or hardware identifiers (collection removed entirely)
- No filesystem contents beyond the project graph
- No API keys or credentials
- No identity.json is created or read

## Compiled MCP server (`graperoot` package)
The `mcp_graph_server` component is distributed as a compiled Python package
(`graperoot` on PyPI). It currently contains a `_ping_license_server()` heartbeat
that contacts a server every 15 minutes with machine identity. This heartbeat is
being removed by the package maintainer in a forthcoming release.

## Always-on mode (stdio MCP)

You can register dual-graph as a global Claude MCP server so it runs
automatically with every `claude` session — no need to use `dgc`:

```bash
claude mcp add --scope user --transport stdio dual-graph -- ~/.dual-graph/dgc-mcp
```

Claude manages the server lifecycle (spawns on session start, kills on exit).
The server is project-scoped: it uses the current working directory as the
project root and stores all data in `.dual-graph/` within that project.

## Network calls that always happen (not gated by flags)
- `pip install graperoot` and other dependencies — standard PyPI package installation
- Localhost-only HTTP between the launcher and the local MCP server
- `bootstrap.pypa.io/get-pip.py` — only during venv creation fallback if pip is missing
