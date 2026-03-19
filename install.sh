#!/usr/bin/env bash
# Dual-Graph one-time setup
# Usage: curl -sSL https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main/install.sh | bash

set -euo pipefail

INSTALL_DIR="$HOME/.dual-graph"
VENV="$INSTALL_DIR/venv"
mkdir -p "$INSTALL_DIR"

# Helper: ask user Y/n, default Y. Returns 0 (true) if yes.
confirm_install() {
  printf "%s [Y/n] " "$1"
  read -r answer </dev/tty
  case "$answer" in
    [Nn]*) return 1 ;;
    *) return 0 ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════════════
# PREREQUISITE CHECK — detect missing tools, ask user, install or stop
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "========================================"
echo "  Dual-Graph Installer"
echo "========================================"
echo ""

NEEDS_RESTART=0
OS_TYPE="$(uname -s)"

# ── Check Python 3.10+ ───────────────────────────────────────────────────────
PYTHON=""
for py in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$py" >/dev/null 2>&1; then
    OK=$("$py" -c "import sys; print(sys.version_info >= (3,10))" 2>/dev/null || echo "False")
    if [[ "$OK" == "True" ]]; then
      PYTHON="$py"
      break
    fi
  fi
done

if [[ -n "$PYTHON" ]]; then
  echo "[check] Python found: $($PYTHON --version)"
else
  echo "[check] Python 3.10+ is NOT installed."
  case "$OS_TYPE" in
    Darwin*)
      if command -v brew >/dev/null 2>&1; then
        if confirm_install "[check] Install Python 3.11 via Homebrew?"; then
          echo "[install] Installing Python 3.11..."
          brew install python@3.11
          PYTHON="python3.11"
          echo "[install] Python 3.11 installed."
        else
          echo ""
          echo "[install] Python 3.10+ is required. Install it manually, then run this installer again:"
          echo "  brew install python@3.11"
          echo "  (or download from https://python.org)"
          exit 0
        fi
      else
        echo "[check] Homebrew not found for automatic install."
        echo "[install] Please install Python 3.11 manually:"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        echo "  brew install python@3.11"
        echo "[install] Then run this installer again."
        exit 0
      fi
      ;;
    Linux*)
      PKG_MGR=""
      if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
      elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
      elif command -v pacman >/dev/null 2>&1; then PKG_MGR="pacman"
      fi

      if [[ -n "$PKG_MGR" ]]; then
        case "$PKG_MGR" in
          apt)    INSTALL_CMD="sudo apt-get update && sudo apt-get install -y python3.11 python3.11-venv" ;;
          dnf)    INSTALL_CMD="sudo dnf install -y python3.11" ;;
          pacman) INSTALL_CMD="sudo pacman -S --noconfirm python" ;;
        esac
        if confirm_install "[check] Install Python via $PKG_MGR? (requires sudo)"; then
          echo "[install] Installing Python..."
          eval "$INSTALL_CMD"
          # Re-detect after install
          for py in python3.13 python3.12 python3.11 python3.10 python3; do
            if command -v "$py" >/dev/null 2>&1; then
              OK=$("$py" -c "import sys; print(sys.version_info >= (3,10))" 2>/dev/null || echo "False")
              if [[ "$OK" == "True" ]]; then PYTHON="$py"; break; fi
            fi
          done
          if [[ -z "$PYTHON" ]]; then
            echo "[install] Python install may have succeeded but isn't on PATH yet."
            echo "[install] Close this terminal, open a new one, and run the installer again."
            exit 0
          fi
          echo "[install] Python installed: $($PYTHON --version)"
        else
          echo ""
          echo "[install] Python 3.10+ is required. Install it manually, then run this installer again:"
          echo "  $INSTALL_CMD"
          exit 0
        fi
      else
        echo "[install] No supported package manager found (apt/dnf/pacman)."
        echo "[install] Please install Python 3.10+ from https://python.org"
        echo "[install] Then run this installer again."
        exit 0
      fi
      ;;
    *)
      echo "[install] Please install Python 3.10+ from https://python.org"
      echo "[install] Then run this installer again."
      exit 0
      ;;
  esac
fi

# ── Check Node.js ─────────────────────────────────────────────────────────────
if command -v node >/dev/null 2>&1; then
  echo "[check] Node.js found: $(node --version)"
else
  echo "[check] Node.js is NOT installed."
  case "$OS_TYPE" in
    Darwin*)
      if command -v brew >/dev/null 2>&1; then
        if confirm_install "[check] Install Node.js LTS via Homebrew?"; then
          echo "[install] Installing Node.js..."
          brew install node
          echo "[install] Node.js installed."
        else
          echo ""
          echo "[install] Node.js is required. Install it manually, then run this installer again:"
          echo "  brew install node"
          echo "  (or download from https://nodejs.org)"
          exit 0
        fi
      else
        echo "[install] Please install Node.js from https://nodejs.org"
        echo "[install] Then run this installer again."
        exit 0
      fi
      ;;
    Linux*)
      PKG_MGR=""
      if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
      elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
      elif command -v pacman >/dev/null 2>&1; then PKG_MGR="pacman"
      fi

      if [[ -n "$PKG_MGR" ]]; then
        case "$PKG_MGR" in
          apt)    INSTALL_CMD="sudo apt-get update && sudo apt-get install -y nodejs npm" ;;
          dnf)    INSTALL_CMD="sudo dnf install -y nodejs npm" ;;
          pacman) INSTALL_CMD="sudo pacman -S --noconfirm nodejs npm" ;;
        esac
        if confirm_install "[check] Install Node.js via $PKG_MGR? (requires sudo)"; then
          echo "[install] Installing Node.js..."
          eval "$INSTALL_CMD"
          if ! command -v node >/dev/null 2>&1; then
            echo "[install] Node.js install may have succeeded but isn't on PATH yet."
            echo "[install] Close this terminal, open a new one, and run the installer again."
            exit 0
          fi
          echo "[install] Node.js installed: $(node --version)"
        else
          echo ""
          echo "[install] Node.js is required. Install it manually, then run this installer again:"
          echo "  $INSTALL_CMD"
          exit 0
        fi
      else
        echo "[install] Please install Node.js from https://nodejs.org"
        echo "[install] Then run this installer again."
        exit 0
      fi
      ;;
    *)
      echo "[install] Please install Node.js from https://nodejs.org"
      echo "[install] Then run this installer again."
      exit 0
      ;;
  esac
fi

# ── Check Claude Code ─────────────────────────────────────────────────────────
if command -v claude >/dev/null 2>&1; then
  echo "[check] Claude Code found."
else
  echo "[check] Claude Code is NOT installed."
  if command -v npm >/dev/null 2>&1; then
    if confirm_install "[check] Install Claude Code via npm?"; then
      echo "[install] Installing Claude Code..."
      npm install -g @anthropic-ai/claude-code 2>&1 || true
      if command -v claude >/dev/null 2>&1; then
        echo "[install] Claude Code installed."
      else
        echo "[install] Warning: Claude Code install may need sudo. Trying with sudo..."
        sudo npm install -g @anthropic-ai/claude-code 2>&1 || true
        if command -v claude >/dev/null 2>&1; then
          echo "[install] Claude Code installed."
        else
          echo "[install] Warning: Could not install Claude Code. Install later:"
          echo "  npm install -g @anthropic-ai/claude-code"
        fi
      fi
    else
      echo "[install] You can install Claude Code later:"
      echo "  npm install -g @anthropic-ai/claude-code"
    fi
  else
    echo "[install] npm not found. Install Claude Code later:"
    echo "  npm install -g @anthropic-ai/claude-code"
  fi
fi

echo ""
echo "[install] All prerequisites satisfied. Installing dual-graph..."
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# MAIN INSTALL
# ══════════════════════════════════════════════════════════════════════════════

echo "[install] Using $($PYTHON --version)"

# Machine identity collection and license validation removed — see PRIVACY.md
# Save install date for one-time feedback prompt (shown only if DG_TELEMETRY=1)
date +%Y-%m-%d > "$INSTALL_DIR/install_date.txt" 2>/dev/null || true

R2="https://pub-18426978d5a14bf4a60ddedd7d5b6dab.r2.dev"
BASE_URL="https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main"

# ── Download core engine ──────────────────────────────────────────────────────
echo "[install] Downloading core engine..."
curl -fsSL "$BASE_URL/bin/dual_graph_launch.sh" -o "$INSTALL_DIR/dual_graph_launch.sh" \
  || curl -fsSL "$R2/dual_graph_launch.sh" -o "$INSTALL_DIR/dual_graph_launch.sh"
chmod +x "$INSTALL_DIR/dual_graph_launch.sh"
curl -sf  "$BASE_URL/bin/version.txt" -o "$INSTALL_DIR/version.txt" 2>/dev/null \
  || curl -sf "$R2/version.txt" -o "$INSTALL_DIR/version.txt" 2>/dev/null \
  || true

echo "[install] Downloading CLI tools..."
curl -fsSL "$BASE_URL/bin/dgc" -o "$INSTALL_DIR/dgc" && chmod +x "$INSTALL_DIR/dgc"
curl -fsSL "$BASE_URL/bin/dg"  -o "$INSTALL_DIR/dg"  && chmod +x "$INSTALL_DIR/dg"

echo "[install] Creating Python venv at $VENV ..."
"$PYTHON" -m venv "$VENV"

echo "[install] Installing Python dependencies..."
"$VENV/bin/pip" install --upgrade pip --quiet
"$VENV/bin/pip" install "mcp>=1.3.0" uvicorn anyio starlette --quiet

# Add to PATH if not already there
SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == */bash ]] && SHELL_RC="$HOME/.bashrc"
if ! grep -q '.dual-graph' "$SHELL_RC" 2>/dev/null; then
  echo 'export PATH="$PATH:$HOME/.dual-graph"' >> "$SHELL_RC"
  echo "[install] Added ~/.dual-graph to PATH in $SHELL_RC"
fi

echo ""
echo "========================================"
echo "  Installation complete!"
echo "========================================"
echo ""
echo "  Run once:"
echo "    source $SHELL_RC"
echo ""
echo "  Then per project:"
echo "    dgc /path/to/project   # Claude Code"
echo "    dg  /path/to/project   # Codex CLI"
echo ""
echo "  Questions, bugs, or feedback? Join the community:"
echo "    https://discord.gg/rxgVVgCh"
