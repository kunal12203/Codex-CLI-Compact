#!/usr/bin/env bash
# Shared local launcher for dual-graph MCP workflows.
# Wrapper scripts:
#   dg  -> codex
#   dgc -> claude

set -Eeuo pipefail

# Opt-in flags (off by default — see PRIVACY.md)
# DG_TELEMETRY=1  → enable error reporting and feedback form
# DG_AUTO_UPDATE=1 → enable launcher self-update
# --no-update      → suppress auto-update for this invocation
_DG_NO_UPDATE=0
for _arg in "$@"; do
  [[ "$_arg" == "--no-update" ]] && _DG_NO_UPDATE=1
done

ASSISTANT="${1:-}"
if [[ "$ASSISTANT" != "codex" && "$ASSISTANT" != "claude" ]]; then
  echo "Usage: $0 <codex|claude> [project_path] [prompt]" >&2
  exit 2
fi
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/venv"
# Windows Git Bash / MSYS2 uses venv/Scripts instead of venv/bin
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* || "$OSTYPE" == win32* ]]; then
  VENV_BIN="$VENV/Scripts"
else
  VENV_BIN="$VENV/bin"
fi
PROJECT="${1:-$(pwd)}"
PROJECT="$(cd "$PROJECT" && pwd)"
PROMPT="${2:-}"
DATA_DIR="$PROJECT/.dual-graph"
TELEMETRY_WEBHOOK="https://script.google.com/macros/s/AKfycbyq_5igbBUORhSqMNktAoX2GQg8BadKcYZOTV-XRUr3vbY3QuK7jjS8EWLg_pZyMDuD/exec"
REPORTED_ERROR=0
CURRENT_STEP="Initializing launcher"

if [[ "$ASSISTANT" == "codex" ]]; then
  TOOL_LABEL="dg"
else
  TOOL_LABEL="dgc"
fi

echo ""
echo "[$TOOL_LABEL] If you receive any errors:"
if [[ "$ASSISTANT" == "codex" ]]; then
  echo "[$TOOL_LABEL]   1. Wait 5 minutes and run dg again"
  echo "[$TOOL_LABEL]   2. Update Codex: npm install -g @openai/codex"
else
  echo "[$TOOL_LABEL]   1. Wait 5 minutes and run dgc again"
  echo "[$TOOL_LABEL]   2. Update Claude Code: npm install -g @anthropic-ai/claude-code"
fi
echo "[$TOOL_LABEL]   3. Join Discord for help: https://discord.gg/rxgVVgCh"
echo ""

_platform_name() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"
  else
    echo "linux"
  fi
}

_machine_id() {
  # Machine identity collection removed — see PRIVACY.md
  echo "disabled"
}

_send_cli_error() {
  [[ "${DG_TELEMETRY:-}" == "1" ]] || return 0
  local step="$1"
  local message="$2"
  local machine_id platform payload
  REPORTED_ERROR=1
  machine_id="$(_machine_id | tr -d '\r\n')"
  platform="$(_platform_name | tr -d '\r\n')"
  payload="$(python3 - "$step" "$message" "$machine_id" "$platform" <<'PY' 2>/dev/null || true
import json, sys
print(json.dumps({
    "type": "cli_error",
    "platform": sys.argv[4],
    "machine_id": sys.argv[3],
    "error_message": sys.argv[2],
    "script_step": sys.argv[1],
}))
PY
)"
  if [[ -n "$payload" ]]; then
    curl -sf -X POST "$TELEMETRY_WEBHOOK" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      >/dev/null 2>&1 || true
  fi
}

_on_launcher_err() {
  local rc="$?"
  if [[ "$ASSISTANT" == "claude" && "$REPORTED_ERROR" != "1" ]]; then
    _send_cli_error "${CURRENT_STEP:-Unknown step}" "Unhandled launcher failure in dual_graph_launch.sh (exit=$rc)"
  fi
  return "$rc"
}

trap '_on_launcher_err' ERR

_version_gt() {
  local remote="$1"
  local local_ver="$2"
  python3 - "$remote" "$local_ver" <<'PY' >/dev/null 2>&1
import sys
def parse(v: str):
    parts = []
    for p in (v or "").strip().split("."):
        try:
            parts.append(int(p))
        except Exception:
            parts.append(0)
    while len(parts) < 4:
        parts.append(0)
    return tuple(parts[:4])
raise SystemExit(0 if parse(sys.argv[1]) > parse(sys.argv[2]) else 1)
PY
}

# ── Kill any stale MCP server for this project (frees its port before scanning) ─
if [[ -f "$DATA_DIR/mcp_server.pid" ]]; then
  _OLD_PID="$(cat "$DATA_DIR/mcp_server.pid")"
  if kill -0 "$_OLD_PID" 2>/dev/null; then
    kill "$_OLD_PID" 2>/dev/null || true
    sleep 0.3
  fi
  rm -f "$DATA_DIR/mcp_server.pid"
fi
# ──────────────────────────────────────────────────────────────────────────────

# Find a free port starting at 8080 (or use DG_MCP_PORT if set)
if [[ -n "${DG_MCP_PORT:-}" ]]; then
  MCP_PORT="$DG_MCP_PORT"
else
  CURRENT_STEP="Selecting port"
  MCP_PORT=8080
  _port_in_use() {
    # Try to actually bind to 0.0.0.0:port (matches server bind address)
    if python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('0.0.0.0', int(sys.argv[1])))
    s.close()
    sys.exit(1)  # port is FREE
except OSError:
    sys.exit(0)  # port is IN USE
" "$1" 2>/dev/null; then
      return 0  # in use
    else
      return 1  # free
    fi
  }
  while _port_in_use "$MCP_PORT"; do
    MCP_PORT=$((MCP_PORT + 1))
    if [[ $MCP_PORT -gt 8199 ]]; then
      echo "[$TOOL_LABEL] Error: no free port found in range 8080-8199" >&2
      exit 1
    fi
  done
fi

if [[ "$ASSISTANT" == "codex" ]]; then
  DOC_FILE="$PROJECT/CODEX.md"
  DOC_NAME="CODEX.md"
  POLICY_MARKER="dg-policy-v5"
  CONTEXT_DIR="$PROJECT/.dual-graph-context"
else
  TOOL_LABEL="dgc"
  DOC_FILE="$PROJECT/CLAUDE.md"
  DOC_NAME="CLAUDE.md"
  POLICY_MARKER="dgc-policy-v10"
fi

# ── Self-update (opt-in: DG_AUTO_UPDATE=1, suppressed by --no-update) ─────────
_LOCAL_VER="$(cat "$SCRIPT_DIR/version.txt" 2>/dev/null || echo "0")"
if [[ "${DG_AUTO_UPDATE:-}" == "1" ]] && [[ "$_DG_NO_UPDATE" != "1" ]]; then
  _R2="https://pub-18426978d5a14bf4a60ddedd7d5b6dab.r2.dev"
  _BASE_URL="https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main"
  _REMOTE_VER="$(
    curl -sf --max-time 3 "$_BASE_URL/bin/version.txt" 2>/dev/null \
      || curl -sf --max-time 3 "$_R2/version.txt" 2>/dev/null \
      || echo ""
  )"
  _NOTICE_FILE="$SCRIPT_DIR/last_update_notice.txt"

  if [[ -n "$_REMOTE_VER" ]] && _version_gt "$_REMOTE_VER" "$_LOCAL_VER"; then
    _LAST_NOTICE_VER="$(cat "$_NOTICE_FILE" 2>/dev/null || echo "")"
    if [[ "$_LAST_NOTICE_VER" != "$_REMOTE_VER" ]]; then
      if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "[$TOOL_LABEL] New version ($_LOCAL_VER -> $_REMOTE_VER) available. To refresh launcher files run:"
        echo "[$TOOL_LABEL]   curl -sSL https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main/install.sh | bash"
      else
        echo "[$TOOL_LABEL] New version ($_LOCAL_VER -> $_REMOTE_VER) available. To refresh launcher files run:"
        echo "[$TOOL_LABEL]   curl -sSL https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main/install.sh | bash"
      fi
      echo "$_REMOTE_VER" > "$_NOTICE_FILE" 2>/dev/null || true
    fi
    echo "[$TOOL_LABEL] Update available ($_LOCAL_VER → $_REMOTE_VER) — updating..."
    curl -fsSL "$_BASE_URL/bin/dual_graph_launch.sh" -o "$SCRIPT_DIR/dual_graph_launch.sh" \
      || curl -fsSL "$_R2/dual_graph_launch.sh" -o "$SCRIPT_DIR/dual_graph_launch.sh"
    chmod +x "$SCRIPT_DIR/dual_graph_launch.sh"
    echo "$_REMOTE_VER" > "$SCRIPT_DIR/version.txt"
    # Upgrade graperoot so venv gets latest mcp_graph_server + compiled modules
    if [[ -x "$VENV_BIN/pip" ]]; then
      "$VENV_BIN/pip" install graperoot --upgrade --quiet 2>/dev/null || true
    fi
    echo "[$TOOL_LABEL] Updated to $_REMOTE_VER. Restarting..."
    EXEC_ARGS=("$SCRIPT_DIR/dual_graph_launch.sh" "$ASSISTANT" "$PROJECT")
    [[ -n "$PROMPT" ]] && EXEC_ARGS+=("$PROMPT")
    exec "${EXEC_ARGS[@]}"
  elif [[ -n "$_REMOTE_VER" && "$_REMOTE_VER" != "$_LOCAL_VER" ]]; then
    echo "[$TOOL_LABEL] Local version ($_LOCAL_VER) is newer than remote ($_REMOTE_VER); skipping downgrade."
  fi
fi
# ──────────────────────────────────────────────────────────────────────────────

# ── Linux dependency checks ──────────────────────────────────────────────────
# On Linux, auto-install missing packages that commonly cause failures.
if [[ "$OSTYPE" != "darwin"* ]]; then
  # curl is required for self-update, hooks, telemetry
  if ! command -v curl &>/dev/null; then
    echo "[$TOOL_LABEL] Installing curl (required)..."
    if command -v apt-get &>/dev/null; then
      sudo apt-get update -qq && sudo apt-get install -y -qq curl 2>/dev/null || true
    elif command -v yum &>/dev/null; then
      sudo yum install -y curl 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y curl 2>/dev/null || true
    elif command -v pacman &>/dev/null; then
      sudo pacman -S --noconfirm curl 2>/dev/null || true
    fi
    if ! command -v curl &>/dev/null; then
      echo "[$TOOL_LABEL] WARNING: curl not found and auto-install failed. Some features may not work."
    fi
  fi

  # python3-venv is needed on Debian/Ubuntu — without it, python3 -m venv fails
  if command -v python3 &>/dev/null && ! python3 -m venv --help &>/dev/null 2>&1; then
    echo "[$TOOL_LABEL] Installing python3-venv (required for setup)..."
    if command -v apt-get &>/dev/null; then
      _PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")"
      sudo apt-get update -qq 2>/dev/null || true
      sudo apt-get install -y -qq "python${_PY_VER}-venv" python3-venv 2>/dev/null || true
    fi
  fi
fi
# ──────────────────────────────────────────────────────────────────────────────

# ── Python discovery & venv setup ────────────────────────────────────────────
# Fallback chain:
#   1. Find a working python3 (PATH → Homebrew → common locations)
#   2. Create venv (python3 -m venv → virtualenv fallback → pip-based virtualenv)
#   3. Install deps (pip install → retry with --no-cache-dir)
# Goal: zero manual intervention for the user.

_find_python3() {
  # 1. PATH python3 (but verify it actually works — macOS Xcode stub may not)
  if command -v python3 &>/dev/null; then
    if python3 -c "import sys; assert sys.version_info >= (3, 10)" 2>/dev/null; then
      command -v python3
      return 0
    fi
  fi

  # 2. Homebrew (macOS)
  local brew_paths=(
    "/opt/homebrew/bin/python3"
    "/usr/local/bin/python3"
    "/opt/homebrew/bin/python3.12"
    "/opt/homebrew/bin/python3.11"
    "/opt/homebrew/bin/python3.10"
    "/usr/local/bin/python3.12"
    "/usr/local/bin/python3.11"
    "/usr/local/bin/python3.10"
  )
  for p in "${brew_paths[@]}"; do
    if [[ -x "$p" ]] && "$p" -c "import sys; assert sys.version_info >= (3, 10)" 2>/dev/null; then
      echo "$p"
      return 0
    fi
  done

  # 3. Linux common paths
  for v in python3.12 python3.11 python3.10; do
    if command -v "$v" &>/dev/null && "$v" -c "import sys; assert sys.version_info >= (3, 10)" 2>/dev/null; then
      command -v "$v"
      return 0
    fi
  done

  return 1
}

_create_venv() {
  local py="$1" venv_dir="$2"

  # Attempt 1: standard venv module
  if "$py" -m venv "$venv_dir" 2>/tmp/dgc_venv_err.txt; then
    return 0
  fi
  echo "[$TOOL_LABEL] venv module failed, trying fallbacks..."
  rm -rf "$venv_dir" 2>/dev/null

  # Attempt 2: venv without pip (ensurepip often the broken part), then bootstrap pip
  if "$py" -m venv --without-pip "$venv_dir" 2>/dev/null; then
    echo "[$TOOL_LABEL] Created venv without pip, bootstrapping pip..."
    local _vpy="$venv_dir/bin/python3"
    [[ ! -x "$_vpy" ]] && _vpy="$venv_dir/Scripts/python"
    if curl -sf --max-time 30 https://bootstrap.pypa.io/get-pip.py | "$_vpy" 2>/dev/null; then
      return 0
    fi
    rm -rf "$venv_dir" 2>/dev/null
  fi

  # Attempt 3: virtualenv (may already be installed)
  if "$py" -m virtualenv "$venv_dir" 2>/dev/null; then
    return 0
  fi
  rm -rf "$venv_dir" 2>/dev/null

  # Attempt 4: install virtualenv via pip then use it
  if "$py" -m pip install --user virtualenv 2>/dev/null && "$py" -m virtualenv "$venv_dir" 2>/dev/null; then
    return 0
  fi
  rm -rf "$venv_dir" 2>/dev/null

  # Attempt 5: uv (fast Python installer — works even without system pip)
  if command -v uv &>/dev/null; then
    echo "[$TOOL_LABEL] Trying uv..."
    if uv venv "$venv_dir" --python 3.12 2>/dev/null || uv venv "$venv_dir" 2>/dev/null; then
      return 0
    fi
    rm -rf "$venv_dir" 2>/dev/null
  fi

  return 1
}

_install_deps() {
  local venv_dir="$1"
  local _bin_dir
  if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* || "$OSTYPE" == win32* ]]; then
    _bin_dir="$venv_dir/Scripts"
  else
    _bin_dir="$venv_dir/bin"
  fi
  local pip_cmd="$_bin_dir/pip"
  local py_cmd
  if [[ -x "$_bin_dir/python3" ]]; then py_cmd="$_bin_dir/python3"; else py_cmd="$_bin_dir/python"; fi

  # Use uv pip if available (10x faster, no build issues)
  if command -v uv &>/dev/null; then
    if uv pip install --python "$py_cmd" "mcp>=1.3.0" uvicorn anyio starlette graperoot 2>/dev/null; then
      return 0
    fi
  fi

  # Standard pip
  if "$pip_cmd" install "mcp>=1.3.0" uvicorn anyio starlette graperoot --quiet 2>/tmp/dgc_pip_err.txt; then
    return 0
  fi

  # Retry without cache (fixes corrupted cache issues)
  echo "[$TOOL_LABEL] Retrying pip install with --no-cache-dir..."
  if "$pip_cmd" install "mcp>=1.3.0" uvicorn anyio starlette graperoot --quiet --no-cache-dir 2>/tmp/dgc_pip_err.txt; then
    return 0
  fi

  return 1
}

if [[ ! -x "$VENV_BIN/python3" ]] && [[ ! -x "$VENV_BIN/python" ]]; then
  CURRENT_STEP="Preparing Python environment"

  # Find a working python3
  _FOUND_PY="$(_find_python3 2>/dev/null)" || _FOUND_PY=""
  if [[ -z "$_FOUND_PY" ]]; then
    echo "[$TOOL_LABEL] ERROR: No working Python 3.10+ found."
    echo "[$TOOL_LABEL] Install Python 3.10+:"
    echo "[$TOOL_LABEL]   macOS:   brew install python@3.12"
    echo "[$TOOL_LABEL]   Ubuntu:  sudo apt install python3 python3-venv"
    echo "[$TOOL_LABEL]   Windows: https://python.org/downloads"
    _send_cli_error "Preparing Python environment" "No Python 3.10+ found in PATH or common locations"
    exit 1
  fi

  _PY_VER="$("$_FOUND_PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "?")"
  echo "[$TOOL_LABEL] Found Python $_PY_VER at $_FOUND_PY"

  # Create venv with fallback chain
  if ! _create_venv "$_FOUND_PY" "$VENV"; then
    _VENV_ERR="$(cat /tmp/dgc_venv_err.txt 2>/dev/null | head -3)"
    echo "[$TOOL_LABEL] ERROR: All venv creation methods failed."
    echo "[$TOOL_LABEL] Last error: $_VENV_ERR"
    echo "[$TOOL_LABEL] Manual fix: $_FOUND_PY -m pip install virtualenv && $_FOUND_PY -m virtualenv $VENV"
    _send_cli_error "Preparing Python environment" "All venv methods failed (py=$_FOUND_PY): $_VENV_ERR"
    exit 1
  fi
  echo "[$TOOL_LABEL] Venv created."

  # Install dependencies
  echo "[$TOOL_LABEL] Installing Python dependencies..."
  if ! _install_deps "$VENV"; then
    _PIP_ERR="$(cat /tmp/dgc_pip_err.txt 2>/dev/null | tail -5)"
    echo "[$TOOL_LABEL] ERROR: Failed to install dependencies."
    echo "[$TOOL_LABEL] $_PIP_ERR"
    _send_cli_error "Preparing Python environment" "pip install failed: $_PIP_ERR"
    exit 1
  fi

elif ! "$VENV_BIN/python3" -c "import mcp, uvicorn, anyio, starlette" 2>/dev/null && \
     ! "$VENV_BIN/python" -c "import mcp, uvicorn, anyio, starlette" 2>/dev/null; then
  CURRENT_STEP="Preparing Python environment"
  echo "[$TOOL_LABEL] Installing missing Python dependencies..."
  if ! _install_deps "$VENV"; then
    _PIP_ERR="$(cat /tmp/dgc_pip_err.txt 2>/dev/null | tail -5)"
    echo "[$TOOL_LABEL] ERROR: Failed to install dependencies."
    echo "[$TOOL_LABEL] $_PIP_ERR"
    _send_cli_error "Preparing Python environment" "pip install (retry) failed: $_PIP_ERR"
    exit 1
  fi
fi

# Windows venv has 'python' not 'python3'
if [[ -x "$VENV_BIN/python3" ]]; then
  PYTHON="$VENV_BIN/python3"
else
  PYTHON="$VENV_BIN/python"
fi

# ── Auto-install compiled graperoot package (falls back to .py if it fails) ──
_GRAPEROOT_OK=0

# Already installed — just verify import works
if "$PYTHON" -c "import graperoot" 2>/dev/null; then
  _GRAPEROOT_OK=1
else
  # Not installed yet — try pip install silently (first run only, ~5s)
  if "$VENV_BIN/pip" install graperoot --upgrade --quiet 2>/dev/null; then
    _GRAPEROOT_OK=1
  fi
  # If pip fails (network, wrong Python version, etc.) — silent fallback to .py
fi

# Safety net: if graperoot missing AND .py fallback is gone, force reinstall
if [[ "$_GRAPEROOT_OK" == "0" ]] && [[ ! -f "$SCRIPT_DIR/graph_builder.py" ]]; then
  echo "[$TOOL_LABEL] graperoot missing and no .py fallback — retrying install..."
  if "$VENV_BIN/pip" install graperoot --upgrade --quiet --no-cache-dir 2>/dev/null; then
    _GRAPEROOT_OK=1
  else
    echo "[$TOOL_LABEL] ERROR: graperoot install failed and no .py fallback available."
    echo "[$TOOL_LABEL] Fix: $VENV_BIN/pip install graperoot"
    exit 1
  fi
fi

# Once compiled package is confirmed working, delete .py source files
if [[ "$_GRAPEROOT_OK" == "1" ]]; then
  rm -f "$SCRIPT_DIR/graph_builder.py" \
        "$SCRIPT_DIR/dg.py" \
        "$SCRIPT_DIR/mcp_graph_server.py" \
        "$SCRIPT_DIR/context_packer.py" \
        "$SCRIPT_DIR/dgc_claude.py" 2>/dev/null || true
fi

# Helper: run graph_builder (compiled or .py)
_run_graph_builder() {
  if [[ "$_GRAPEROOT_OK" == "1" ]]; then
    "$VENV_BIN/graph-builder" "$@"
  else
    "$PYTHON" "$SCRIPT_DIR/graph_builder.py" "$@"
  fi
}

# Resolve MCP server to a real executable array (env/nohup can't call shell functions)
if [[ "$_GRAPEROOT_OK" == "1" ]]; then
  _MCP_CMD=("$VENV_BIN/mcp-graph-server")
else
  _MCP_CMD=("$PYTHON" "$SCRIPT_DIR/mcp_graph_server.py")
fi

echo "[$TOOL_LABEL] Project : $PROJECT"
echo "[$TOOL_LABEL] Data    : $DATA_DIR"
echo ""

mkdir -p "$DATA_DIR"

if [[ -f "$PROJECT/.gitignore" ]] && ! grep -qx '.dual-graph/' "$PROJECT/.gitignore" 2>/dev/null; then
  echo '.dual-graph/' >> "$PROJECT/.gitignore"
  echo "[$TOOL_LABEL] Added .dual-graph/ to .gitignore"
fi

if [[ "$ASSISTANT" == "codex" ]] && [[ -f "$PROJECT/.gitignore" ]] && ! grep -qx '.dual-graph-context/' "$PROJECT/.gitignore" 2>/dev/null; then
  echo '.dual-graph-context/' >> "$PROJECT/.gitignore"
  echo "[$TOOL_LABEL] Added .dual-graph-context/ to .gitignore"
fi

_ensure_codex_context_files() {
  [[ "$ASSISTANT" == "codex" ]] || return 0

  mkdir -p "$CONTEXT_DIR/packs"

  if [[ ! -f "$CONTEXT_DIR/PROJECT_CONTEXT.md" ]]; then
    cat > "$CONTEXT_DIR/PROJECT_CONTEXT.md" << 'EOF'
# PROJECT_CONTEXT

## Product Goal
- What are we building and for whom?

## Architecture Snapshot
- Main services/apps:
- Key data flow:
- Critical dependencies:

## Non-Negotiable Constraints
- Security / compliance:
- Performance targets:
- Tech constraints:

## Definition Of Done
- Release criteria:
- Test/validation criteria:

## Out Of Scope
- Explicitly excluded changes:
EOF
  fi

  if [[ ! -f "$CONTEXT_DIR/SESSION_CONTEXT.md" ]]; then
    cat > "$CONTEXT_DIR/SESSION_CONTEXT.md" << 'EOF'
# SESSION_CONTEXT

## Current Objective
- What outcome should this session produce?

## Active Scope
- In-scope modules/files:
- Out-of-scope modules/files:

## Acceptance Criteria
- Concrete checks this task must pass:

## Decisions / Assumptions
- Decision:
- Why:

## Open Questions
- Missing details that block implementation:
EOF
  fi

  if [[ ! -f "$CONTEXT_DIR/packs/README.md" ]]; then
    cat > "$CONTEXT_DIR/packs/README.md" << 'EOF'
# Context Packs

Use one file per domain area. Examples:
- auth.md
- billing.md
- checkout.md
- notifications.md

Keep each pack short and factual:
- domain rules
- edge cases
- invariants
- API contracts
EOF
  fi
}

_write_codex_policy_doc() {
  cat > "$DOC_FILE" << EOF
<!-- $POLICY_MARKER -->
# Dual-Graph Context Policy

This project uses a local dual-graph MCP server for efficient context retrieval.

## Context Layering (Codex Only)

- Use layered context files:
  - \`.dual-graph-context/PROJECT_CONTEXT.md\` for stable project context.
  - \`.dual-graph-context/SESSION_CONTEXT.md\` for current in-chat scope.
  - \`.dual-graph-context/packs/*.md\` for domain-specific context packs.
- Never ask for "full context" or entire chat history.
- Ask only for missing sections, one short question at a time.
- If a domain is missing context, request only that pack (for example: "please share billing context pack").

## MANDATORY: Always follow this order

1. **Call \`graph_continue\` first** — before any file exploration, grep, or code reading.

2. **If \`graph_continue\` returns \`needs_project=true\`**: call \`graph_scan\` with the
   current project directory (\`pwd\`). Do NOT ask the user.

3. **If \`graph_continue\` returns \`skip=true\`**: project has fewer than 5 files.
   Do NOT do broad or recursive exploration. Read only specific files if their names
   are mentioned, or ask the user what to work on.

4. **Load context layers before implementation decisions**:
   - Read \`.dual-graph-context/PROJECT_CONTEXT.md\` and \`.dual-graph-context/SESSION_CONTEXT.md\` when available.
   - Read only relevant \`.dual-graph-context/packs/*.md\` files for the current task.
   - If critical context is missing, ask one scoped question and continue after answer.

5. **Read \`recommended_files\`** using \`graph_read\` — **one call per file**.
   - \`graph_read\` accepts a single \`file\` parameter (string). Call it separately for each
     recommended file. Do NOT pass an array or batch multiple files into one call.
   - \`recommended_files\` may contain \`file::symbol\` entries (e.g. \`src/auth.ts::handleLogin\`).
     Pass them verbatim to \`graph_read(file: "src/auth.ts::handleLogin")\` — it reads only
     that symbol's lines, not the full file.
   - Example: if \`recommended_files\` is \`["src/auth.ts::handleLogin", "src/db.ts"]\`,
     call \`graph_read(file: "src/auth.ts::handleLogin")\` and \`graph_read(file: "src/db.ts")\`
     as two separate calls (they can be parallel).

6. **Check \`confidence\` and obey the caps strictly:**
   - \`confidence=high\` -> Stop. Do NOT grep or explore further.
   - \`confidence=medium\` -> If recommended files are insufficient, call \`fallback_rg\`
     at most \`max_supplementary_greps\` time(s) with specific terms, then \`graph_read\`
     at most \`max_supplementary_files\` additional file(s). Then stop.
   - \`confidence=low\` -> Call \`fallback_rg\` at most \`max_supplementary_greps\` time(s),
     then \`graph_read\` at most \`max_supplementary_files\` file(s). Then stop.

## Rules

- Do NOT use \`rg\`, \`grep\`, or bash file exploration before calling \`graph_continue\`.
- Do NOT do broad/recursive exploration at any confidence level.
- \`max_supplementary_greps\` and \`max_supplementary_files\` are hard caps - never exceed them.
- Do NOT dump full chat history.
- Do context handshake per task: summarize known context, then ask for only missing pieces.
- Do NOT call \`graph_retrieve\` more than once per turn.
- After edits, call \`graph_register_edit\` with the changed files. Use \`file::symbol\` notation (e.g. \`src/auth.ts::handleLogin\`) when the edit targets a specific function, class, or hook.
EOF
}

_write_claude_policy_doc() {
  cat > "$DOC_FILE" << EOF
<!-- $POLICY_MARKER -->
# Dual-Graph Context Policy

This project uses a local dual-graph MCP server for efficient context retrieval.

## MANDATORY: Always follow this order

1. **Call \`graph_continue\` first** — before any file exploration, grep, or code reading.

2. **If \`graph_continue\` returns \`needs_project=true\`**: call \`graph_scan\` with the
   current project directory (\`pwd\`). Do NOT ask the user.

3. **If \`graph_continue\` returns \`skip=true\`**: project has fewer than 5 files.
   Do NOT do broad or recursive exploration. Read only specific files if their names
   are mentioned, or ask the user what to work on.

4. **Read \`recommended_files\`** using \`graph_read\` — **one call per file**.
   - \`graph_read\` accepts a single \`file\` parameter (string). Call it separately for each
     recommended file. Do NOT pass an array or batch multiple files into one call.
   - \`recommended_files\` may contain \`file::symbol\` entries (e.g. \`src/auth.ts::handleLogin\`).
     Pass them verbatim to \`graph_read(file: "src/auth.ts::handleLogin")\` — it reads only
     that symbol's lines, not the full file.
   - Example: if \`recommended_files\` is \`["src/auth.ts::handleLogin", "src/db.ts"]\`,
     call \`graph_read(file: "src/auth.ts::handleLogin")\` and \`graph_read(file: "src/db.ts")\`
     as two separate calls (they can be parallel).

5. **Check \`confidence\` and obey the caps strictly:**
   - \`confidence=high\` -> Stop. Do NOT grep or explore further.
   - \`confidence=medium\` -> If recommended files are insufficient, call \`fallback_rg\`
     at most \`max_supplementary_greps\` time(s) with specific terms, then \`graph_read\`
     at most \`max_supplementary_files\` additional file(s). Then stop.
   - \`confidence=low\` -> Call \`fallback_rg\` at most \`max_supplementary_greps\` time(s),
     then \`graph_read\` at most \`max_supplementary_files\` file(s). Then stop.

## Token Usage

A \`token-counter\` MCP is available for tracking live token usage.

- To check how many tokens a large file or text will cost **before** reading it:
  \`count_tokens({text: "<content>"})\`
- To log actual usage after a task completes (if the user asks):
  \`log_usage({input_tokens: <est>, output_tokens: <est>, description: "<task>"})\`
- To show the user their running session cost:
  \`get_session_stats()\`

Live dashboard URL is printed at startup next to "Token usage".

## Rules

- Do NOT use \`rg\`, \`grep\`, or bash file exploration before calling \`graph_continue\`.
- Do NOT do broad/recursive exploration at any confidence level.
- \`max_supplementary_greps\` and \`max_supplementary_files\` are hard caps - never exceed them.
- Do NOT dump full chat history.
- Do NOT call \`graph_retrieve\` more than once per turn.
- After edits, call \`graph_register_edit\` with the changed files. Use \`file::symbol\` notation (e.g. \`src/auth.ts::handleLogin\`) when the edit targets a specific function, class, or hook.

## Context Store

Whenever you make a decision, identify a task, note a next step, fact, or blocker during a conversation, append it to \`.dual-graph/context-store.json\`.

**Entry format:**
\`\`\`json
{"type": "decision|task|next|fact|blocker", "content": "one sentence max 15 words", "tags": ["topic"], "files": ["relevant/file.ts"], "date": "YYYY-MM-DD"}
\`\`\`

**To append:** Read the file → add the new entry to the array → Write it back → call \`graph_register_edit\` on \`.dual-graph/context-store.json\`.

**Rules:**
- Only log things worth remembering across sessions (not every minor detail)
- \`content\` must be under 15 words
- \`files\` lists the files this decision/task relates to (can be empty)
- Log immediately when the item arises — not at session end

## Session End

When the user signals they are done (e.g. "bye", "done", "wrap up", "end session"), proactively update \`CONTEXT.md\` in the project root with:
- **Current Task**: one sentence on what was being worked on
- **Key Decisions**: bullet list, max 3 items
- **Next Steps**: bullet list, max 3 items

Keep \`CONTEXT.md\` under 20 lines total. Do NOT summarize the full conversation — only what's needed to resume next session.
EOF
}

_write_policy_doc() {
  if [[ "$ASSISTANT" == "codex" ]]; then
    _write_codex_policy_doc
  else
    _write_claude_policy_doc
  fi
}

_ensure_codex_context_files

if [[ ! -f "$DOC_FILE" ]]; then
  echo "[$TOOL_LABEL] Creating $DOC_NAME ..."
  _write_policy_doc
  echo "[$TOOL_LABEL] $DOC_NAME created."
elif ! grep -q "$POLICY_MARKER" "$DOC_FILE"; then
  echo "[$TOOL_LABEL] Upgrading $DOC_NAME to v10 policy ..."
  _write_policy_doc
  echo "[$TOOL_LABEL] $DOC_NAME upgraded."
else
  echo "[$TOOL_LABEL] $DOC_NAME already up to date, skipping."
fi

# Init context store if missing
if [[ ! -f "$DATA_DIR/context-store.json" ]]; then
  echo "[]" > "$DATA_DIR/context-store.json"
fi

echo "[$TOOL_LABEL] Scanning project..."
CURRENT_STEP="Scanning project"
_SCAN_ERR_FILE="$DATA_DIR/scan_error.log"
rm -f "$_SCAN_ERR_FILE" 2>/dev/null || true
_SCAN_OK=0
if _run_graph_builder --root "$PROJECT" --out "$DATA_DIR/info_graph.json" 2>"$_SCAN_ERR_FILE"; then
  _SCAN_OK=1
else
  # Auto-fix: reinstall Python deps and retry once
  echo "[$TOOL_LABEL] Scan failed — reinstalling Python deps and retrying..."
  _install_deps "$VENV" 2>/dev/null || true
  rm -f "$_SCAN_ERR_FILE" 2>/dev/null || true
  if _run_graph_builder --root "$PROJECT" --out "$DATA_DIR/info_graph.json" 2>"$_SCAN_ERR_FILE"; then
    _SCAN_OK=1
  fi
fi
if [[ "$_SCAN_OK" != "1" ]]; then
  echo "[$TOOL_LABEL] Error: project scan failed after retry."
  _SCAN_TAIL="$(tail -n 20 "$_SCAN_ERR_FILE" 2>/dev/null | tr '\n' ' ' | tr '\r' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-700)"
  [[ -z "$_SCAN_TAIL" ]] && _SCAN_TAIL="no stderr captured"
  _send_cli_error "Scanning project" "Project scan failed in dual_graph_launch.sh: $_SCAN_TAIL"
  exit 1
fi
rm -f "$_SCAN_ERR_FILE" 2>/dev/null || true
echo "[$TOOL_LABEL] Scan complete."
echo ""

echo "[$TOOL_LABEL] Port    : $MCP_PORT"
echo ""

CURRENT_STEP="Starting MCP server"
env \
  DG_DATA_DIR="$DATA_DIR" \
  DUAL_GRAPH_PROJECT_ROOT="$PROJECT" \
  DG_BASE_URL="http://localhost:$MCP_PORT" \
  PORT="$MCP_PORT" \
  "${_MCP_CMD[@]}" \
  >> "$DATA_DIR/mcp_server.log" 2>&1 &
MCP_PID=$!
echo "$MCP_PID" > "$DATA_DIR/mcp_server.pid"
echo "$MCP_PORT" > "$DATA_DIR/mcp_port"
trap 'echo ""; echo "[$TOOL_LABEL] Shutting down MCP server (PID $MCP_PID)..."; kill "$MCP_PID" 2>/dev/null; rm -f "$DATA_DIR/mcp_server.pid" "$DATA_DIR/mcp_port"' EXIT INT TERM HUP

echo "[$TOOL_LABEL] Waiting for MCP server..."
CURRENT_STEP="Waiting for MCP server"
_MCP_READY=0
for i in $(seq 1 20); do
  if nc -z localhost "$MCP_PORT" 2>/dev/null || \
     python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.5); sys.exit(0 if s.connect_ex(('127.0.0.1',$MCP_PORT))==0 else 1)" 2>/dev/null; then
    _MCP_READY=1
    break
  fi
  sleep 1
done

if [[ "$_MCP_READY" != "1" ]]; then
  # Auto-fix: kill stale process, pick new port, restart once
  echo "[$TOOL_LABEL] MCP server did not start — restarting on new port..."
  kill "$MCP_PID" 2>/dev/null || true
  MCP_PORT=$((MCP_PORT + 1))
  env \
    DG_DATA_DIR="$DATA_DIR" \
    DUAL_GRAPH_PROJECT_ROOT="$PROJECT" \
    DG_BASE_URL="http://localhost:$MCP_PORT" \
    PORT="$MCP_PORT" \
    "${_MCP_CMD[@]}" \
    >> "$DATA_DIR/mcp_server.log" 2>&1 &
  MCP_PID=$!
  echo "$MCP_PID" > "$DATA_DIR/mcp_server.pid"
  echo "$MCP_PORT" > "$DATA_DIR/mcp_port"
  trap 'echo ""; echo "[$TOOL_LABEL] Shutting down MCP server (PID $MCP_PID)..."; kill "$MCP_PID" 2>/dev/null; rm -f "$DATA_DIR/mcp_server.pid" "$DATA_DIR/mcp_port"' EXIT INT TERM HUP
  _MCP_READY=0
  for i in $(seq 1 15); do
    if nc -z localhost "$MCP_PORT" 2>/dev/null || \
       python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.5); sys.exit(0 if s.connect_ex(('127.0.0.1',$MCP_PORT))==0 else 1)" 2>/dev/null; then
      _MCP_READY=1
      break
    fi
    sleep 1
  done
  if [[ "$_MCP_READY" != "1" ]]; then
    echo "[$TOOL_LABEL] Error: MCP server did not start after retry. Check $DATA_DIR/mcp_server.log"
    _send_cli_error "Starting MCP server" "MCP server did not start in dual_graph_launch.sh (retried)"
    exit 1
  fi
  echo "[$TOOL_LABEL] MCP server recovered on port $MCP_PORT."
fi

echo "[$TOOL_LABEL] MCP server ready on port $MCP_PORT (PID $MCP_PID)."
echo ""

# ── Context hooks (Claude only) ────────────────────────────────────────────────
# Writes SessionStart + PreCompact hooks so graph context survives auto-compaction.
if [[ "$ASSISTANT" == "claude" ]]; then
  cat > "$DATA_DIR/prime.sh" << PRIMEEOF
#!/usr/bin/env bash
PORT=\$(cat "$DATA_DIR/mcp_port" 2>/dev/null || echo $MCP_PORT)
OUT=\$(curl -sf --max-time 2 "http://localhost:\$PORT/prime" 2>/dev/null || true)
if [[ -n "\$OUT" ]]; then
  echo "\$OUT"
fi
# Inject CONTEXT.md if it exists (session carry-over, ~200 tokens)
if [[ -f "$PROJECT/CONTEXT.md" ]]; then
  echo ""
  echo "=== CONTEXT.md ==="
  cat "$PROJECT/CONTEXT.md"
  echo "=== end CONTEXT.md ==="
fi
# Inject context store entries (decisions, tasks, next steps) — max 15 lines, 7-day window
STORE="$PROJECT/.dual-graph/context-store.json"
if [[ -f "\$STORE" ]] && command -v jq &>/dev/null; then
  CUTOFF=\$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d 2>/dev/null || echo "2000-01-01")
  ENTRIES=\$(jq -r --arg cutoff "\$CUTOFF" \
    '[.[] | select(.date >= \$cutoff)] | .[:15] | .[] | "[" + .type + "] " + .content' \
    "\$STORE" 2>/dev/null)
  if [[ -n "\$ENTRIES" ]]; then
    echo ""
    echo "=== Stored Context ==="
    echo "\$ENTRIES"
    echo "=== end Stored Context ==="
  fi
fi
# Never fail hooks due to stderr/exit behavior.
exit 0
PRIMEEOF
  chmod +x "$DATA_DIR/prime.sh"

  # Write stop.sh — reads transcript, sums real API usage, POSTs to token counter
  # Uses an offset file to only count NEW lines since last stop (avoids double-counting on resume)
  cat > "$DATA_DIR/stop.sh" << STOPEOF
#!/usr/bin/env bash
INPUT=\$(cat)
TRANSCRIPT=\$(echo "\$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || echo "")
if [[ -n "\$TRANSCRIPT" && -f "\$TRANSCRIPT" ]]; then
  USAGE=\$(python3 - "\$TRANSCRIPT" 2>/dev/null << 'PYEOF'
import json, sys, os
transcript = sys.argv[1]
offset_file = transcript + ".stopoffset"
start_line = 0
if os.path.exists(offset_file):
    try:
        start_line = int(open(offset_file).read().strip())
    except Exception:
        start_line = 0
input_tokens = cache_create = cache_read = output_tokens = 0
model = ""
lines = open(transcript).readlines()
for line in lines[start_line:]:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    if msg.get("type") != "assistant":
        continue
    m = msg.get("message", {})
    if not model:
        model = m.get("model", "")
    u = m.get("usage", {})
    if not u:
        continue
    input_tokens += u.get("input_tokens", 0)
    cache_create += u.get("cache_creation_input_tokens", 0)
    cache_read += u.get("cache_read_input_tokens", 0)
    output_tokens += u.get("output_tokens", 0)
# Save current line count so next stop only counts new lines
try:
    with open(offset_file, "w") as f:
        f.write(str(len(lines)))
except Exception:
    pass
if input_tokens > 0 or cache_create > 0 or cache_read > 0 or output_tokens > 0:
    print(json.dumps({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_creation_input_tokens": cache_create,
        "cache_read_input_tokens": cache_read,
        "model": model or "claude-sonnet-4-6",
        "description": "auto",
        "project": "$PROJECT",
    }))
PYEOF
)
  if [[ -n "\$USAGE" ]]; then
    # POST to MCP graph server (always running, reliable)
    MCP_PORT=\$(cat "$DATA_DIR/mcp_port" 2>/dev/null || echo "$MCP_PORT")
    curl -sf -X POST "http://localhost:\$MCP_PORT/log" \
      -H "Content-Type: application/json" \
      -d "\$USAGE" \
      >/dev/null 2>&1 || true
    # Also POST to token-counter-mcp dashboard if available
    PORT_FILE="\$HOME/.claude/token-counter/dashboard-port.txt"
    DASH_PORT=8899
    if [[ -f "\$PORT_FILE" ]]; then DASH_PORT=\$(cat "\$PORT_FILE"); fi
    curl -sf -X POST "http://localhost:\$DASH_PORT/log" \
      -H "Content-Type: application/json" \
      -d "\$USAGE" \
      >/dev/null 2>&1 || true
  fi
fi
exit 0
STOPEOF
  chmod +x "$DATA_DIR/stop.sh"

  mkdir -p "$PROJECT/.claude"
  PRIME_CMD="$DATA_DIR/prime.sh"
  # Write JSON via Python to avoid quoting/escaping issues in paths with spaces.
  "$PYTHON" - "$PROJECT/.claude/settings.local.json" "$PRIME_CMD" "$DATA_DIR/stop.sh" <<'PY'
import json, sys, platform
settings_file = sys.argv[1]
prime_cmd = sys.argv[2]
stop_cmd = sys.argv[3]
# Use plain "bash" on Windows (Git Bash resolves it); /bin/bash on Unix
bash = "bash" if platform.system() == "Windows" else "/bin/bash"
hook_cmd = f'{bash} "{prime_cmd}"'
stop_hook_cmd = f'{bash} "{stop_cmd}"'
payload = {
    "hooks": {
        "SessionStart": [
            {"matcher": "", "hooks": [{"type": "command", "command": hook_cmd}]}
        ],
        "PreCompact": [
            {"matcher": "", "hooks": [{"type": "command", "command": hook_cmd}]}
        ],
        "Stop": [
            {"matcher": "", "hooks": [{"type": "command", "command": stop_hook_cmd}]}
        ],
    }
}
with open(settings_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY
  echo "[$TOOL_LABEL] Context hooks ready (SessionStart + PreCompact)"
fi
# ──────────────────────────────────────────────────────────────────────────────

if [[ "$ASSISTANT" == "codex" ]]; then
  CURRENT_STEP="Registering MCP"

  # Auto-install codex CLI if missing
  if ! command -v codex &>/dev/null; then
    echo "[$TOOL_LABEL] codex CLI not found — installing..."
    if command -v npm &>/dev/null; then
      npm install -g @openai/codex >/dev/null 2>&1 || true
    fi
    # Refresh PATH for npm global bin
    export PATH="$PATH:$(npm config get prefix 2>/dev/null)/bin:$HOME/.npm-global/bin:$HOME/.local/bin"
    if ! command -v codex &>/dev/null; then
      echo "[$TOOL_LABEL] ERROR: could not auto-install codex CLI."
      echo "[$TOOL_LABEL]   npm install -g @openai/codex"
      _send_cli_error "Registering MCP" "codex CLI not found, auto-install failed"
      exit 1
    fi
    echo "[$TOOL_LABEL] codex CLI installed."
  fi

  # Auto-install mcp-remote if missing (Codex needs stdio bridge)
  if ! command -v mcp-remote &>/dev/null && ! npx mcp-remote --help &>/dev/null 2>&1; then
    echo "[$TOOL_LABEL] mcp-remote not found — installing..."
    npm install -g mcp-remote >/dev/null 2>&1 || true
    export PATH="$PATH:$(npm config get prefix 2>/dev/null)/bin"
  fi

  codex mcp remove dual-graph >/dev/null 2>&1 || true
  # Codex CLI only supports stdio MCP — use mcp-remote to bridge HTTP->stdio
  _CODEX_REG_OK=0
  _CODEX_REG_ERR=""
  # Try npx first, then global mcp-remote
  if _CODEX_REG_ERR="$(codex mcp add dual-graph -- npx mcp-remote "http://localhost:$MCP_PORT/mcp" 2>&1)"; then
    _CODEX_REG_OK=1
  elif _CODEX_REG_ERR="$(codex mcp add dual-graph -- mcp-remote "http://localhost:$MCP_PORT/mcp" 2>&1)"; then
    _CODEX_REG_OK=1
  fi

  if [[ "$_CODEX_REG_OK" != "1" ]]; then
    # Auto-fix: reinstall both deps and retry once
    echo "[$TOOL_LABEL] MCP registration failed — reinstalling deps and retrying..."
    npm install -g @openai/codex mcp-remote >/dev/null 2>&1 || true
    export PATH="$PATH:$(npm config get prefix 2>/dev/null)/bin"
    codex mcp remove dual-graph >/dev/null 2>&1 || true
    if _CODEX_REG_ERR="$(codex mcp add dual-graph -- npx mcp-remote "http://localhost:$MCP_PORT/mcp" 2>&1)"; then
      _CODEX_REG_OK=1
    elif _CODEX_REG_ERR="$(codex mcp add dual-graph -- mcp-remote "http://localhost:$MCP_PORT/mcp" 2>&1)"; then
      _CODEX_REG_OK=1
    fi
  fi

  if [[ "$_CODEX_REG_OK" == "1" ]]; then
    echo "[$TOOL_LABEL] MCP config updated -> http://localhost:$MCP_PORT/mcp (via mcp-remote)"
  else
    echo "[$TOOL_LABEL] Error: failed to register MCP with codex after auto-fix."
    echo "[$TOOL_LABEL] stderr: $_CODEX_REG_ERR"
    echo "[$TOOL_LABEL] Manual fix:"
    echo "[$TOOL_LABEL]   npm install -g @openai/codex mcp-remote"
    echo "[$TOOL_LABEL]   Then run dg again."
    echo "[$TOOL_LABEL] If it still fails, join Discord: https://discord.gg/rxgVVgCh"
    _send_cli_error "Registering MCP" "MCP registration failed after auto-fix (codex): $_CODEX_REG_ERR"
    exit 1
  fi
else
  CURRENT_STEP="Registering MCP"

  # Auto-install claude CLI if missing
  if ! command -v claude &>/dev/null; then
    echo "[$TOOL_LABEL] claude CLI not found — installing..."
    if command -v npm &>/dev/null; then
      npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 || true
    fi
    export PATH="$PATH:$(npm config get prefix 2>/dev/null)/bin:$HOME/.npm-global/bin:$HOME/.local/bin"
    if ! command -v claude &>/dev/null; then
      echo "[$TOOL_LABEL] ERROR: could not auto-install claude CLI."
      echo "[$TOOL_LABEL]   npm install -g @anthropic-ai/claude-code"
      _send_cli_error "Registering MCP" "claude CLI not found, auto-install failed"
      exit 1
    fi
    echo "[$TOOL_LABEL] claude CLI installed."
  fi

  claude mcp remove dual-graph >/dev/null 2>&1 || true
  _MCP_REG_OK=0
  _MCP_REG_ERR=""
  if _MCP_REG_ERR="$(claude mcp add --transport http dual-graph "http://localhost:$MCP_PORT/mcp" 2>&1)"; then
    _MCP_REG_OK=1
  elif _MCP_REG_ERR="$(claude mcp add --transport sse dual-graph "http://localhost:$MCP_PORT/mcp" 2>&1)"; then
    _MCP_REG_OK=1
  elif _MCP_REG_ERR="$(claude mcp add dual-graph "http://localhost:$MCP_PORT/mcp" 2>&1)"; then
    _MCP_REG_OK=1
  fi

  if [[ "$_MCP_REG_OK" != "1" ]]; then
    # Auto-fix: update CLI and retry once
    echo "[$TOOL_LABEL] MCP registration failed — updating claude CLI and retrying..."
    npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 || true
    export PATH="$PATH:$(npm config get prefix 2>/dev/null)/bin"
    claude mcp remove dual-graph >/dev/null 2>&1 || true
    if _MCP_REG_ERR="$(claude mcp add --transport http dual-graph "http://localhost:$MCP_PORT/mcp" 2>&1)"; then
      _MCP_REG_OK=1
    elif _MCP_REG_ERR="$(claude mcp add --transport sse dual-graph "http://localhost:$MCP_PORT/mcp" 2>&1)"; then
      _MCP_REG_OK=1
    elif _MCP_REG_ERR="$(claude mcp add dual-graph "http://localhost:$MCP_PORT/mcp" 2>&1)"; then
      _MCP_REG_OK=1
    fi
  fi

  if [[ "$_MCP_REG_OK" != "1" ]]; then
    echo "[$TOOL_LABEL] Error: failed to register MCP with claude after auto-fix."
    echo "[$TOOL_LABEL] stderr: $_MCP_REG_ERR"
    echo "[$TOOL_LABEL] Manual fix:"
    echo "[$TOOL_LABEL]   npm install -g @anthropic-ai/claude-code"
    echo "[$TOOL_LABEL]   Then run dgc again."
    echo "[$TOOL_LABEL] If it still fails, join Discord: https://discord.gg/rxgVVgCh"
    _send_cli_error "Registering MCP" "MCP registration failed after auto-fix (claude): $_MCP_REG_ERR"
    exit 1
  fi
  echo "[$TOOL_LABEL] MCP config updated -> http://localhost:$MCP_PORT/mcp"

  # ── Token Counter MCP (global user scope — works in all projects) ────────
  claude mcp remove token-counter --scope user >/dev/null 2>&1 || true
  claude mcp remove token-counter >/dev/null 2>&1 || true
  claude mcp add --scope user token-counter -- npx -y token-counter-mcp >/dev/null 2>&1 || true
  _TC_PORT_FILE="$HOME/.claude/token-counter/dashboard-port.txt"
  _TC_PORT=8899
  if [[ -f "$_TC_PORT_FILE" ]]; then _TC_PORT=$(cat "$_TC_PORT_FILE"); fi
  echo "[$TOOL_LABEL] Token counter -> http://localhost:$_TC_PORT (global)"
  # ───────────────────────────────────────────────────────────────────────────
fi

# ── One-time feedback form (opt-in: DG_TELEMETRY=1) ───────────────────────────
_FEEDBACK_DONE="$SCRIPT_DIR/feedback_done"
_INSTALL_DATE_FILE="$SCRIPT_DIR/install_date.txt"
if [[ "${DG_TELEMETRY:-}" == "1" ]] && [[ ! -f "$_FEEDBACK_DONE" ]] && [[ -t 0 ]]; then
  _SHOW_FEEDBACK=1
  if [[ -f "$_INSTALL_DATE_FILE" ]]; then
    _INSTALL_DATE="$(cat "$_INSTALL_DATE_FILE")"
    if ! python3 - "$_INSTALL_DATE" <<'PY' >/dev/null 2>&1; then
from datetime import date
import sys
try:
    install = date.fromisoformat(sys.argv[1].strip())
    ready = (date.today() - install).days >= 2
    raise SystemExit(0 if ready else 1)
except Exception:
    raise SystemExit(1)
PY
      _SHOW_FEEDBACK=0
    fi
  fi
  if [[ "$_SHOW_FEEDBACK" == "1" ]]; then
    echo "===================================================="
    echo "  One quick question before we start (asked once only)"
    echo "===================================================="
    printf "  How useful has Graperoot been so far? (1-5): "
    read -r _FB_RATING < /dev/tty || _FB_RATING=""
    printf "  Anything you'd improve? (press Enter to skip): "
    read -r _FB_IMPROVE < /dev/tty || _FB_IMPROVE=""
    _MACHINE_ID="$(cat "$SCRIPT_DIR/identity.json" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('machine_id','unknown'))" 2>/dev/null || echo "unknown")"
    curl -sf -X POST "https://script.google.com/macros/s/AKfycbzsOnvAiDTdhDaW73ErztJztPqT25WOCFn29VzrRYZRhBUIwHRu677DoATctAEiq6dp4Q/exec" \
      -H "Content-Type: application/json" \
      -d "{\"rating\":\"$_FB_RATING\",\"improve\":\"$_FB_IMPROVE\",\"machine_id\":\"$_MACHINE_ID\"}" \
      >/dev/null 2>&1 || true
    touch "$_FEEDBACK_DONE"
    echo "  Thanks! You won't see this again."
    echo "===================================================="
    echo ""
  fi
fi
# ──────────────────────────────────────────────────────────────────────────────

# ── Pre-flight checks ────────────────────────────────────────────────────────
CURRENT_STEP="Pre-flight checks"

# 1. Verify the CLI tool is installed and in PATH (should already be fixed at registration step, but double-check)
if ! command -v "$ASSISTANT" &>/dev/null; then
  # Refresh PATH one more time
  export PATH="$PATH:$(npm config get prefix 2>/dev/null)/bin:$HOME/.npm-global/bin:$HOME/.local/bin"
  if ! command -v "$ASSISTANT" &>/dev/null; then
    echo "[$TOOL_LABEL] ERROR: '$ASSISTANT' CLI not found in PATH."
    if [[ "$ASSISTANT" == "claude" ]]; then
      echo "[$TOOL_LABEL]   npm install -g @anthropic-ai/claude-code"
    else
      echo "[$TOOL_LABEL]   npm install -g @openai/codex"
    fi
    _send_cli_error "Pre-flight checks" "$ASSISTANT CLI not found after auto-install"
    exit 1
  fi
fi

# 2. Verify Node.js version >= 18 (Claude Code requirement)
if command -v node &>/dev/null; then
  _NODE_VER="$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)"
  if [[ -n "$_NODE_VER" && "$_NODE_VER" -lt 18 ]] 2>/dev/null; then
    echo "[$TOOL_LABEL] ERROR: Node.js v$_NODE_VER found, but Claude Code requires Node.js 18+."
    echo "[$TOOL_LABEL] Upgrade Node.js:"
    echo "[$TOOL_LABEL]   https://nodejs.org/en/download"
    echo "[$TOOL_LABEL]   Or: fnm install 22 && fnm use 22"
    _send_cli_error "Pre-flight checks" "Node.js too old: v$_NODE_VER (need 18+)"
    exit 1
  fi
fi

# 3. Quick smoke test — verify CLI responds (catches broken installs, missing deps)
if ! "$ASSISTANT" --version &>/dev/null 2>&1; then
  echo "[$TOOL_LABEL] WARNING: '$ASSISTANT --version' failed. The CLI may not work correctly."
  echo "[$TOOL_LABEL] Try reinstalling: npm install -g @anthropic-ai/claude-code"
fi

# 4. Verify MCP server is still alive (it may have crashed between startup and now)
if ! kill -0 "$MCP_PID" 2>/dev/null; then
  echo "[$TOOL_LABEL] ERROR: MCP server (PID $MCP_PID) died before Claude started."
  _MCP_LOG_TAIL="$(tail -n 20 "$DATA_DIR/mcp_server.log" 2>/dev/null | tr '\n' ' ' | cut -c1-500)"
  echo "[$TOOL_LABEL] Last log: $_MCP_LOG_TAIL"
  echo "[$TOOL_LABEL] Try running dgc again. If it persists, join Discord: https://discord.gg/rxgVVgCh"
  _send_cli_error "Pre-flight checks" "MCP server died before Claude started: $_MCP_LOG_TAIL"
  exit 1
fi

# ── Launch CLI ───────────────────────────────────────────────────────────────
echo ""
echo "[$TOOL_LABEL] Starting $ASSISTANT..."
echo ""

CURRENT_STEP="Changing to project directory"
cd "$PROJECT" || {
  _send_cli_error "Changing to project directory" "Cannot cd to project: $PROJECT"
  exit 1
}
CURRENT_STEP="Running Claude"
# Disable ERR trap — some bash versions (esp. Linux) fire ERR despite set +e,
# causing spurious "Unhandled launcher failure" telemetry.
trap - ERR
set +e
if [[ -n "$PROMPT" ]]; then
  "$ASSISTANT" "$PROMPT" 2>"$DATA_DIR/assistant_stderr.log"
else
  "$ASSISTANT" 2>"$DATA_DIR/assistant_stderr.log"
fi
ASSISTANT_EXIT=$?
set -e

# Ignore normal termination: 0=clean, 130=SIGINT (Ctrl+C), 143=SIGTERM
if [[ "$ASSISTANT_EXIT" -ne 0 && "$ASSISTANT_EXIT" -ne 130 && "$ASSISTANT_EXIT" -ne 143 ]]; then
  _STDERR_TAIL="$(tail -n 10 "$DATA_DIR/assistant_stderr.log" 2>/dev/null | tr '\n' ' ' | cut -c1-500)"
  echo ""
  echo "[$TOOL_LABEL] $ASSISTANT exited with code $ASSISTANT_EXIT."
  if [[ -n "$_STDERR_TAIL" ]]; then
    echo "[$TOOL_LABEL] Error output: $_STDERR_TAIL"
  fi
  echo "[$TOOL_LABEL] Troubleshooting:"
  if [[ "$ASSISTANT" == "claude" ]]; then
    echo "[$TOOL_LABEL]   1. Update Claude Code: npm install -g @anthropic-ai/claude-code"
  else
    echo "[$TOOL_LABEL]   1. Update Codex: npm install -g @openai/codex"
  fi
  echo "[$TOOL_LABEL]   2. Try running '$ASSISTANT' directly to see if it works"
  echo "[$TOOL_LABEL]   3. Run dgc again — it may be a transient issue"
  echo "[$TOOL_LABEL]   4. Join Discord for help: https://discord.gg/rxgVVgCh"
  _send_cli_error "Running $ASSISTANT" "$ASSISTANT exited=$ASSISTANT_EXIT stderr=$_STDERR_TAIL"
fi
# Clean up stderr log on success
[[ "$ASSISTANT_EXIT" -eq 0 ]] && rm -f "$DATA_DIR/assistant_stderr.log" 2>/dev/null
exit "$ASSISTANT_EXIT"
