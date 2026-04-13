.PHONY: \
	install \
	graph-setup graph-scan graph-start graph-stop graph-dgc graph-dg

# Default target
.DEFAULT_GOAL := help

# Detect OS for platform-specific commands
UNAME := $(shell uname -s 2>/dev/null || echo Windows)

# ============================================================================
# HELP
# ============================================================================

help: ## Show this help message
	@echo "Usage: make <target>"
	@echo ""
	@echo "Setup:"
	@grep -E '^install[a-zA-Z_-]*:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Dual-Graph:"
	@grep -E '^graph[a-zA-Z_-]*:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ============================================================================
# SETUP
# ============================================================================

install: ## Install Python deps (graperoot + dashboard requirements)
	pip install -r requirements.txt

# ============================================================================
# DUAL-GRAPH
# ============================================================================

graph-setup: ## Install graperoot for local development (run once per machine)
	@command -v graph-builder >/dev/null 2>&1 || pip install graperoot --upgrade
	@echo "graperoot ready. Run 'make graph-scan' to build the semantic graph."

graph-scan: ## Build the semantic graph for this repo (run after cloning or major changes)
	@command -v graph-builder >/dev/null 2>&1 || { echo "Error: graperoot not installed. Run: make graph-setup"; exit 1; }
	@mkdir -p .dual-graph
	@echo "Scanning project..."
	@graph-builder --root . --out .dual-graph/info_graph.json
	@echo "Graph saved to .dual-graph/info_graph.json"

graph-start: ## Start the MCP server on port 8080 (background). Pairs with .mcp.json.
	@command -v mcp-graph-server >/dev/null 2>&1 || { echo "Error: graperoot not installed. Run: make graph-setup"; exit 1; }
	@mkdir -p .dual-graph
	@[ -f .dual-graph/info_graph.json ] || { echo "No graph found. Run: make graph-scan"; exit 1; }
	@echo "Starting MCP server on port 8080..."
	@DG_DATA_DIR=.dual-graph DUAL_GRAPH_PROJECT_ROOT=. PORT=8080 \
		mcp-graph-server >> .dual-graph/mcp_server.log 2>&1 & \
		echo $$! > .dual-graph/mcp_server.pid
	@sleep 1 && echo "MCP server running (PID $$(cat .dual-graph/mcp_server.pid)). Connect via .mcp.json."

graph-stop: ## Stop the background MCP server
	@if [ -f .dual-graph/mcp_server.pid ]; then \
		kill "$$(cat .dual-graph/mcp_server.pid)" 2>/dev/null && \
		echo "MCP server stopped." || echo "Server was not running."; \
		rm -f .dual-graph/mcp_server.pid; \
	else \
		echo "No PID file found — server may not be running."; \
	fi

graph-dgc: ## Launch Claude Code with dual-graph (full setup: scan + MCP + claude)
	@command -v dgc >/dev/null 2>&1 || { echo "Error: dgc not installed. Run: curl -sSL https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main/install.sh | bash"; exit 1; }
	dgc .

graph-dg: ## Launch Codex CLI with dual-graph (full setup: scan + MCP + codex)
	@command -v dg >/dev/null 2>&1 || { echo "Error: dg not installed. Run: curl -sSL https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main/install.sh | bash"; exit 1; }
	dg .
