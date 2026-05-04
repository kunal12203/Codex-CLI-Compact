@echo off
REM dg-mcp.cmd — Standalone Dual-Graph MCP server (no IDE launch)

setlocal enabledelayedexpansion
cd /d "%~dp0"

set "PROJECT=%CD%"
set "DISABLE_TELEMETRY=0"
set "PREFER_PORT="

:parse_args
if "%~1"=="" goto args_done
if "%~1"=="--help" goto show_help
if "%~1"=="-h" goto show_help
if "%~1"=="--no-telemetry" (
  set "DISABLE_TELEMETRY=1"
  shift
  goto parse_args
)
if "%~1"=="--port" (
  set "PREFER_PORT=%~2"
  shift
  shift
  goto parse_args
)
if "%~1:~0,7%"=="--port=" (
  set "PREFER_PORT=%~1:~7%"
  shift
  goto parse_args
)
if "%~1:~0,1%"=="-" (
  echo Unknown option: %~1 >&2
  exit /b 1
)
set "PROJECT=%~1"
shift
goto parse_args

:show_help
echo dg-mcp — Standalone Dual-Graph MCP server (no IDE launch)
echo.
echo USAGE:
echo   dg-mcp [project_path]
echo.
echo EXAMPLES:
echo   dg-mcp                     # Start MCP for current directory
echo   dg-mcp C:\path\to\project  # Start MCP for a specific project
echo.
echo OPTIONS:
echo   --help, -h                 Show this help message
echo   --no-telemetry             Disable telemetry (one-time opt-out)
echo   --port N                   Use a specific port (default: auto 8080+)
echo.
echo ENVIRONMENT VARIABLES:
echo   DG_MCP_PORT                Use a specific port instead of auto-selecting
echo.
echo OUTPUT:
echo   Prints MCP server URL and connection info to stdout.
echo   Keep the process running to maintain the server.
echo   Press Ctrl+C to stop.
exit /b 0

:args_done
if not "%PREFER_PORT%"=="" set "DG_MCP_PORT=%PREFER_PORT%"
if "%DISABLE_TELEMETRY%"=="1" set "DG_DISABLE_TELEMETRY=1"
set "DG_MCP_ONLY=1"
call "%~dp0dual_graph_launch.sh" "mcp-only" "%PROJECT%"
