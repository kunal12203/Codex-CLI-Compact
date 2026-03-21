# Dual-Graph — Compounding Context for Claude Code & Codex CLI

A context engine that makes Claude Code and Codex CLI **30-45% cheaper** without sacrificing quality. It builds a semantic graph of your codebase and pre-loads the right files into every prompt — so Claude spends tokens reasoning, not exploring.

Works on **macOS, Linux, and Windows**. Supports any project size.

Supports **TypeScript, JavaScript, Python, Go, Swift, Rust, Java, Kotlin, C#, Ruby, and PHP**.

**Join the community: [discord.gg/ptyr7KJz](https://discord.gg/ptyr7KJz)**

---

## How It Works

```
You run: dgc /path/to/project
         ↓
1. Project scanned → semantic graph built (files, symbols, imports)
2. You ask a question
3. Graph identifies the relevant files → packs them into context
4. Claude gets your question + the right code already loaded
5. Fewer turns, fewer tokens, better answers
```

Token savings **compound** across a session. The graph remembers which files were read, edited, and queried — each turn gets cheaper.

---

## Results

Benchmarked across 80+ prompts (5 complexity levels) on a real-world full-stack app:

| Metric | Without Dual-Graph | With Dual-Graph |
|--------|-------------------|-----------------|
| Avg cost per prompt | $0.46 | **$0.27** |
| Avg turns | 16.8 | **10.3** |
| Avg response time | 186s | **134s** |
| Quality (regex scorer) | 82.7/100 | **87.1/100** |

Cost wins on **16 out of 20** prompts. Quality equal or better on all complexity levels.

---

## Install

**macOS / Linux:**
```bash
curl -sSL https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main/install.sh | bash
source ~/.zshrc   # or ~/.bashrc / ~/.profile
```

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main/install.ps1 | iex
```

**Windows (Scoop):**
```powershell
scoop bucket add dual-graph https://github.com/kunal12203/scoop-dual-graph
scoop install dual-graph
```

**Prerequisites:** Python 3.10+, Node.js 18+, Claude Code or Codex CLI. The installer detects missing tools and offers to install them via winget (Windows) or homebrew (macOS).

---

## Usage

### Claude Code (`dgc`)

```bash
dgc                              # scan current directory, launch Claude
dgc /path/to/project             # scan a specific project
dgc /path/to/project "fix the login bug"   # start with a prompt
```

### Codex CLI (`dg`)

```bash
dg                               # scan current directory, launch Codex
dg /path/to/project              # scan a specific project
dg /path/to/project "add tests"  # start with a prompt
```

### Windows

```powershell
dgc .                            # from inside the project directory
dgc "D:\projects\my-app"         # any drive, any path
dg "C:\work\backend"             # Codex CLI
```

---

## What It Does Under the Hood

1. **Scans your project** — extracts files, functions, classes, import relationships into a local graph. Supports TS/JS, Python, Go, Swift, Rust, Java, Kotlin, C#, Ruby, and PHP.
2. **Pre-loads context** — when you ask a question, the graph ranks relevant files and packs them into the prompt before Claude sees it. No extra tool calls needed.
3. **Remembers across turns** — files you've read or edited are prioritized in future turns. Context compounds.
4. **MCP tools available** — Claude can still explore the codebase via graph-aware tools (`graph_read`, `graph_retrieve`, `graph_neighbors`, etc.) when it needs to go deeper.

All processing is local. No code leaves your machine.

---

## Data & Files

All data lives in `<project>/.dual-graph/` (gitignored automatically).

| File | Description |
|---|---|
| `info_graph.json` | Semantic graph of the project: files, symbols, edges |
| `chat_action_graph.json` | Session memory: reads, edits, queries, decisions |
| `context-store.json` | Persistent store for decisions/tasks/facts across sessions |
| `mcp_server.log` | MCP server logs |
| `graph_snapshots/info_graph_<ts>.json` | Timestamped snapshot of info_graph.json saved before each rescan. Last 5 retained. |
| `graph_snapshots/info_graph_<ts>.meta.json` | Sidecar metadata: scan trigger, file count, and action log offset at snapshot time. Links a snapshot directly to the mcp_tool_calls.jsonl entries that followed. |

Global files in `~/.dual-graph/`:
| File | Description |
|---|---|
| `dgc.ps1` / `dg.ps1` | Launcher scripts (auto-updated) |
| `venv/` | Python virtual environment for dependencies |
| `version.txt` | Current installed version |

---

## Configuration

All optional, via environment variables:

| Variable | Default | Description |
|---|---|---|
| `DG_HARD_MAX_READ_CHARS` | `4000` | Max characters per file read |
| `DG_TURN_READ_BUDGET_CHARS` | `18000` | Total read budget per turn |
| `DG_FALLBACK_MAX_CALLS_PER_TURN` | `1` | Max fallback grep calls per turn |
| `DG_RETRIEVE_CACHE_TTL_SEC` | `900` | Retrieval cache TTL (15 min) |
| `DG_MCP_PORT` | auto (8080-8099) | Force a specific MCP server port |

---

## Context Store

Decisions, tasks, and facts from your sessions are persisted in `.dual-graph/context-store.json` and re-injected at the start of the next session. This gives Claude continuity across conversations.

You can also create a `CONTEXT.md` in your project root for free-form session notes.

---

## Token Tracking

A token-counter dashboard is registered automatically with Claude Code:

```
http://localhost:8899
```

Usage from inside a Claude session:
```
count_tokens({text: "<content>"})   # estimate tokens before reading
get_session_stats()                  # running session cost
```

---

## Self-Update

The launcher checks for updates on every run and auto-updates if a new version is available. No manual intervention needed.

Current version: **3.9.46**

---

## Privacy & Security

- **All project data stays local.** Graphs, session data, and code never leave your machine.
- The only outbound calls are:
  - **Version check** — fetches a version string (no project data).
  - **Heartbeat** — sends a random install ID and `platform` only. No hardware fingerprinting, no file names, no code.
  - **One-time feedback** — optional rating after first day of use.
- `.dual-graph/` is automatically added to `.gitignore`.

---

## Uninstall

**macOS / Linux:**
```bash
rm -rf ~/.dual-graph
sed -i.bak '/\.dual-graph/d' ~/.zshrc ~/.bashrc 2>/dev/null
rm -rf .dual-graph .claude/settings.local.json
claude mcp remove token-counter --scope user 2>/dev/null
claude mcp remove dual-graph 2>/dev/null
rm -rf ~/.claude/token-counter
rm -f ~/.claude/token-counter-stop.sh
```

**Windows (PowerShell):**
```powershell
Remove-Item "$env:USERPROFILE\.dual-graph" -Recurse -Force -ErrorAction SilentlyContinue
$p = [Environment]::GetEnvironmentVariable("PATH","User") -split ";" | Where-Object { $_ -notlike "*\.dual-graph*" }
[Environment]::SetEnvironmentVariable("PATH", ($p -join ";"), "User")
Remove-Item ".dual-graph" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ".claude\settings.local.json" -Force -ErrorAction SilentlyContinue
claude mcp remove token-counter --scope user 2>$null
claude mcp remove dual-graph 2>$null
Remove-Item "$env:USERPROFILE\.claude\token-counter" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.claude\token-counter-stop.ps1" -Force -ErrorAction SilentlyContinue
```

> The PATH/project commands remove the global install. Run the project-local commands inside each project you used dual-graph with.

---

## Contributing

The launcher scripts (`bin/`) are open source under Apache 2.0. PRs are welcome — bug fixes, new AI assistant support, install improvements, docs.

**Note:** The graph engine ([`graperoot`](https://pypi.org/project/graperoot/)) is a separate proprietary component distributed via PyPI. The launcher scripts and tooling in this repo are fully open source; the core graph intelligence is not.

---

## Community

Have a question, found a bug, or want to share feedback?

**Join the Discord: [discord.gg/ptyr7KJz](https://discord.gg/ptyr7KJz)**

- Get help with setup
- Report bugs
- Share workflows
- Follow releases

---

## Acknowledgements

A huge thank you to everyone who used early versions of Dual-Graph and shared feedback through the telemetry program — your usage data helped us squash bugs and stabilize the tool into what it is today. We've now removed all telemetry in favor of full transparency.

Want to keep helping shape the project? **[Join the Discord](https://discord.gg/ptyr7KJz)**

---

## License

The launcher scripts and tooling in this repository are licensed under the [Apache License 2.0](./LICENSE).

The `graperoot` graph engine (installed as a PyPI dependency) is proprietary and not covered by this license.
