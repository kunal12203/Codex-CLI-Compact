# dg-mcp.ps1 — Standalone Dual-Graph MCP server (no IDE launch)
#
# Usage:
#   .\dg-mcp.ps1                          # start MCP server for current directory
#   .\dg-mcp.ps1 -Project C:\path\to\project
#   .\dg-mcp.ps1 -Help

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RawArgs
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommandPath
$Project = (Get-Location).Path
$DisableTelemetry = $false
$PreferPort = ""

# Parse arguments
$i = 0
while ($i -lt $RawArgs.Count) {
    $arg = $RawArgs[$i]
    
    if ($arg -eq "--help" -or $arg -eq "-h") {
        Write-Host "dg-mcp — Standalone Dual-Graph MCP server (no IDE launch)
USAGE:
  dg-mcp.ps1 [project_path]
  ./dg-mcp.ps1 -Help

EXAMPLES:
  ./dg-mcp.ps1                           # Start MCP for current directory
  ./dg-mcp.ps1 C:\path\to\project        # Start MCP for a specific project

OPTIONS:
  --help, -h                 Show this help message
  --no-telemetry             Disable telemetry (one-time opt-out)
  --port N                   Use a specific port (default: auto 8080+)

ENVIRONMENT VARIABLES:
  DG_MCP_PORT                Use a specific port instead of auto-selecting

OUTPUT:
  Prints MCP server URL and connection info to stdout.
  Keep the process running to maintain the server.
  Press Ctrl+C to stop."
        exit 0
    }
    elseif ($arg -eq "--no-telemetry") {
        $DisableTelemetry = $true
    }
    elseif ($arg -eq "--port") {
        if ($i + 1 -lt $RawArgs.Count) {
            $PreferPort = $RawArgs[$i + 1]
            $i += 1
        }
    }
    elseif ($arg -like "--port=*") {
        $PreferPort = $arg.Substring(7)
    }
    elseif ($arg -like "-*") {
        Write-Host "Unknown option: $arg" -ForegroundColor Red
        exit 1
    }
    else {
        $Project = $arg
    }
    
    $i += 1
}

# Set environment variables
if ($PreferPort) {
    $env:DG_MCP_PORT = $PreferPort
}
if ($DisableTelemetry) {
    $env:DG_DISABLE_TELEMETRY = "1"
}
$env:DG_MCP_ONLY = "1"

# Call main launcher
& "$ScriptDir\dual_graph_launch.sh" "mcp-only" "$Project"
