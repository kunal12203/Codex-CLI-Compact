# dg - Codex CLI + dual-graph MCP launcher (PowerShell)
param(
    [Parameter(Position = 0)]
    [string]$ProjectPath = "."
)

$ErrorActionPreference = "Stop"

$DG = Join-Path $env:USERPROFILE ".dual-graph"
$Tool = "dg"
$R2 = "https://pub-18426978d5a14bf4a60ddedd7d5b6dab.r2.dev"
$BaseUrl = "https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main"
$Python = Join-Path $DG "venv\Scripts\python.exe"
$NoticeFile = Join-Path $DG "last_update_notice.txt"

function Get-MachineId {
    $identityPath = Join-Path $DG "identity.json"
    try {
        if (Test-Path $identityPath) {
            $identity = Get-Content $identityPath -Raw | ConvertFrom-Json
            if ($identity.machine_id -and $identity.installed_date) { return "$($identity.machine_id)" }
            # Existing users: just stamp installed_date, keep their ID intact
            if ($identity.machine_id) {
                $identity | Add-Member -NotePropertyName installed_date -NotePropertyValue (Get-Date -Format "yyyy-MM-dd") -Force
                [System.IO.File]::WriteAllText($identityPath, ($identity | ConvertTo-Json -Compress))
                return "$($identity.machine_id)"
            }
        }
    } catch {}
    # No identity.json or no machine_id  -  generate a random one and save it
    try {
        $mid = [System.Guid]::NewGuid().ToString("N")
        $identity = @{ machine_id = $mid; platform = "windows"; installed_date = (Get-Date -Format "yyyy-MM-dd"); tool = "launcher-ps1" }
        New-Item -ItemType Directory -Force -Path $DG | Out-Null
        [System.IO.File]::WriteAllText($identityPath, ($identity | ConvertTo-Json -Compress))
        return $mid
    } catch {}
    return "unknown"
}

function Get-Text([string]$Uri) {
    $response = Invoke-WebRequest $Uri -UseBasicParsing -TimeoutSec 5
    $content = $response.Content
    if ($content -is [byte[]]) {
        return ([System.Text.Encoding]::UTF8.GetString($content)).Trim()
    }
    if ($content -is [System.Array]) {
        return ([System.Text.Encoding]::UTF8.GetString([byte[]]$content)).Trim()
    }
    return ([string]$content).Trim()
}

function Download-File([string]$Primary, [string]$Fallback, [string]$OutFile) {
    # Download to a temp file first, then move atomically  -  prevents corrupt partial writes
    # if the network drops mid-download (which would leave $OutFile half-written and unparseable).
    $tmp = $OutFile + ".tmp"
    try {
        Invoke-WebRequest $Primary -OutFile $tmp -UseBasicParsing -TimeoutSec 15
        if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) {
            Move-Item $tmp $OutFile -Force
            return $true
        }
    } catch {}
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($Fallback) {
        try {
            Invoke-WebRequest $Fallback -OutFile $tmp -UseBasicParsing -TimeoutSec 15
            if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) {
                Move-Item $tmp $OutFile -Force
                return $true
            }
        } catch {}
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function Get-FreePort {
    for ($port = 8080; $port -le 8199; $port++) {
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $port)
            $listener.Start()
            $listener.Stop()
            return $port
        } catch {}
    }
    throw "no free port in range 8080-8199"
}

function Wait-Port([int]$Port, [int]$Tries = 20) {
    for ($i = 0; $i -lt $Tries; $i++) {
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(500)) {
                $client.EndConnect($async)
                $client.Close()
                return $true
            }
            $client.Close()
        } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-NativeQuiet([string]$FilePath, [string[]]$Arguments) {
    $hasNativePref = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePref) { $previousNativePref = $PSNativeCommandUseErrorActionPreference }
    try {
        if ($hasNativePref) { $global:PSNativeCommandUseErrorActionPreference = $false }
        & $FilePath @Arguments > $null 2>&1
        return $LASTEXITCODE
    } finally {
        if ($hasNativePref) { $global:PSNativeCommandUseErrorActionPreference = $previousNativePref }
    }
}

function Stop-McpServer([string]$PidFile, [string]$PortFile) {
    if (Test-Path $PidFile) {
        try { Stop-Process -Id ([int](Get-Content $PidFile -Raw)) -Force -ErrorAction SilentlyContinue } catch {}
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $PortFile) {
        try {
            $p = [int](Get-Content $PortFile -Raw)
            Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
        } catch {}
        Remove-Item $PortFile -Force -ErrorAction SilentlyContinue
    }
}

function Find-Python3 {
    try {
        $p = (Get-Command python3 -ErrorAction SilentlyContinue).Source
        if ($p) {
            $ver = & python3 -c "import sys; print(sys.version_info >= (3, 10))" 2>$null
            if ($ver -eq "True") { return $p }
        }
    } catch {}
    try {
        $p = (Get-Command python -ErrorAction SilentlyContinue).Source
        if ($p -and $p -notmatch 'WindowsApps') {
            $ver = & python -c "import sys; print(sys.version_info >= (3, 10))" 2>$null
            if ($ver -eq "True") { return $p }
        }
    } catch {}
    try {
        $p = (Get-Command py -ErrorAction SilentlyContinue).Source
        if ($p) {
            $ver = & py -3 -c "import sys; print(sys.version_info >= (3, 10))" 2>$null
            if ($ver -eq "True") { return "py -3" }
        }
    } catch {}
    $paths = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe",
        "C:\Python310\python.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            try {
                $ver = & $p -c "import sys; print(sys.version_info >= (3, 10))" 2>$null
                if ($ver -eq "True") { return $p }
            } catch {}
        }
    }
    foreach ($conda in @("$env:USERPROFILE\miniconda3\python.exe", "$env:USERPROFILE\anaconda3\python.exe",
                         "C:\ProgramData\miniconda3\python.exe", "C:\ProgramData\anaconda3\python.exe")) {
        if (Test-Path $conda) {
            try {
                $ver = & $conda -c "import sys; print(sys.version_info >= (3, 10))" 2>$null
                if ($ver -eq "True") { return $conda }
            } catch {}
        }
    }
    return $null
}

function Create-Venv([string]$PyExe, [string]$VenvDir) {
    if ($PyExe -eq "py -3") {
        $exit = Invoke-NativeQuiet "py" @("-3", "-m", "venv", $VenvDir)
        if ($exit -eq 0 -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) { return $true }
        Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
        $exit = Invoke-NativeQuiet "py" @("-3", "-m", "venv", "--without-pip", $VenvDir)
        if ($exit -eq 0 -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) {
            try {
                $getPip = Join-Path $env:TEMP "get-pip.py"
                Invoke-WebRequest "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip -UseBasicParsing -TimeoutSec 30
                & (Join-Path $VenvDir "Scripts\python.exe") $getPip 2>$null
                if (Test-Path (Join-Path $VenvDir "Scripts\pip.exe")) { return $true }
            } catch {}
        }
        Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
    $exit = Invoke-NativeQuiet $PyExe @("-m", "venv", "--clear", $VenvDir)
    if ($exit -eq 0 -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) { return $true }
    cmd /c "rmdir /s /q `"$VenvDir`"" 2>$null
    Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
    $exit = Invoke-NativeQuiet $PyExe @("-m", "venv", "--clear", "--without-pip", $VenvDir)
    if ($exit -eq 0 -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) {
        try {
            Write-Host "[$Tool] Bootstrapping pip via get-pip.py..."
            $getPip = Join-Path $env:TEMP "get-pip.py"
            Invoke-WebRequest "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip -UseBasicParsing -TimeoutSec 30
            & (Join-Path $VenvDir "Scripts\python.exe") $getPip 2>$null
            if (Test-Path (Join-Path $VenvDir "Scripts\pip.exe")) { return $true }
        } catch {}
    }
    Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
    $exit = Invoke-NativeQuiet $PyExe @("-m", "virtualenv", $VenvDir)
    if ($exit -eq 0 -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) { return $true }
    Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-NativeQuiet $PyExe @("-m", "pip", "install", "--user", "virtualenv") | Out-Null
    $exit = Invoke-NativeQuiet $PyExe @("-m", "virtualenv", $VenvDir)
    if ($exit -eq 0 -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) { return $true }
    Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
    return $false
}

try {
    if (-not (Test-Path $DG)) { New-Item -ItemType Directory -Force -Path $DG | Out-Null }

    # -- Clean up stale venv tombstones in background (venv._old_* and venv._broken_*) --
    Get-ChildItem -Path $DG -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^venv\.(_old_|_broken_)' } |
        ForEach-Object {
            $stale = $_.FullName
            Start-Job -ScriptBlock { cmd /c "rmdir /s /q `"$using:stale`"" } -ErrorAction SilentlyContinue | Out-Null
        }

    # -- Self-update check (FIRST -- before venv/graperoot so stuck users always escape) --
    $localVer = "0"
    $versionFile = Join-Path $DG "version.txt"
    if (Test-Path $versionFile) { $localVer = (Get-Content $versionFile -Raw).Trim() }
    $remoteVer = ""
    try { $remoteVer = Get-Text "$BaseUrl/bin/version.txt" } catch {
        try { $remoteVer = Get-Text "$R2/version.txt" } catch {}
    }
    if ($remoteVer) {
        try {
            if ([version]$remoteVer -gt [version]$localVer) {
                if (-not (Test-Path $NoticeFile) -or ((Get-Content $NoticeFile -Raw).Trim() -ne $remoteVer)) {
                    Write-Host "[$Tool] New version available: $localVer -> $remoteVer"
                    Set-Content -Path $NoticeFile -Value $remoteVer -Encoding UTF8
                }
                Write-Host "[$Tool] Update available: $localVer -> $remoteVer ... updating"
                $downloads = @(
                    @{ Primary = "$R2/dual_graph_launch.sh"; Fallback = "$BaseUrl/bin/dual_graph_launch.sh"; Out = (Join-Path $DG "dual_graph_launch.sh") },
                    @{ Primary = "$R2/dgc.ps1";             Fallback = "$BaseUrl/bin/dgc.ps1";            Out = (Join-Path $DG "dgc.ps1") },
                    @{ Primary = "$R2/dg.ps1";              Fallback = "$BaseUrl/bin/dg.ps1";             Out = (Join-Path $DG "dg.ps1") },
                    @{ Primary = "$R2/dgc.cmd";             Fallback = "$BaseUrl/bin/dgc.cmd";            Out = (Join-Path $DG "dgc.cmd") },
                    @{ Primary = "$R2/dg.cmd";              Fallback = "$BaseUrl/bin/dg.cmd";             Out = (Join-Path $DG "dg.cmd") },
                    @{ Primary = "$R2/graperoot.ps1";       Fallback = "$BaseUrl/bin/graperoot.ps1";      Out = (Join-Path $DG "graperoot.ps1") },
                    @{ Primary = "$R2/graperoot.cmd";       Fallback = "$BaseUrl/bin/graperoot.cmd";      Out = (Join-Path $DG "graperoot.cmd") }
                )
                foreach ($item in $downloads) { [void](Download-File $item.Primary $item.Fallback $item.Out) }
                $dgPs1 = Join-Path $DG "dg.ps1"
                if ((Test-Path $dgPs1) -and (Get-Item $dgPs1).Length -gt 1024) {
                    [void](Download-File "$R2/version.txt" "$BaseUrl/bin/version.txt" (Join-Path $DG "version.txt"))
                }
                # Upgrade graperoot so venv gets latest mcp_graph_server + compiled modules
                $venvPip = Join-Path $DG "venv\Scripts\pip.exe"
                if (Test-Path $venvPip) { Invoke-NativeQuiet $venvPip @("install", "graperoot", "--upgrade", "--quiet") | Out-Null }
                # Show changelog for new version (max 3 lines)
                try {
                    $changelog = ""
                    try { $changelog = (Invoke-WebRequest -Uri "$BaseUrl/bin/changelog.txt" -TimeoutSec 5 -UseBasicParsing).Content } catch {
                        try { $changelog = (Invoke-WebRequest -Uri "$R2/changelog.txt" -TimeoutSec 5 -UseBasicParsing).Content } catch {}
                    }
                    if ($changelog) {
                        $notes = @(); $inVer = $false
                        foreach ($line in $changelog -split "`n") {
                            $line = $line.TrimEnd()
                            if ($line -eq $remoteVer) { $inVer = $true; continue }
                            if ($inVer) {
                                if ($line -eq "" -and $notes.Count -gt 0) { break }
                                if ($line.StartsWith("-")) { $notes += $line.Trim() }
                                if ($notes.Count -eq 3) { break }
                            }
                        }
                        if ($notes.Count -gt 0) {
                            Write-Host "[$Tool] What's new in $remoteVer`:"
                            foreach ($n in $notes) { Write-Host "[$Tool]   $n" }
                        }
                    }
                } catch {}
                Write-Host "[$Tool] Updated to $remoteVer. Restarting..."
                $updatedScript = Join-Path $DG "dg.ps1"
                if (Test-Path $updatedScript) { & $updatedScript $ProjectPath; exit $LASTEXITCODE }
            }
        } catch {}
    }

    # -- Bulletproof Python venv setup --
    $venvCfg = Join-Path $DG "venv\pyvenv.cfg"
    $needsVenv = (-not (Test-Path $Python)) -or (-not (Test-Path $venvCfg))
    if ($needsVenv -and (Test-Path (Join-Path $DG "venv"))) {
        Write-Host "[$Tool] Broken venv detected (missing pyvenv.cfg). Rebuilding..."
        $oldVenv = Join-Path $DG "venv"

        # Step 1: Kill any python.exe running from the venv (locks .pyd files)
        Write-Host "[$Tool] Stopping stale Python processes..."
        try {
            Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ExecutablePath -like "*\.dual-graph*" } |
                ForEach-Object {
                    Write-Host "[$Tool]   Killing PID $($_.ProcessId)..."
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                }
        } catch {}
        taskkill /f /fi "IMAGENAME eq python.exe" /fi "MODULES eq _pydantic_core*" 2>$null | Out-Null
        Start-Sleep -Seconds 2

        # Step 2: Try rmdir first (most reliable on Windows)
        cmd /c "rmdir /s /q `"$oldVenv`"" 2>$null
        if (Test-Path $oldVenv) {
            # Step 3: Rename out of the way if rmdir failed
            $tombstone = Join-Path $DG "venv._broken_$(Get-Date -Format 'yyyyMMddHHmmss')"
            try {
                Rename-Item $oldVenv $tombstone -Force -ErrorAction Stop
                Start-Job -ScriptBlock { cmd /c "rmdir /s /q `"$using:tombstone`"" } -ErrorAction SilentlyContinue | Out-Null
            } catch {
                Remove-Item "$oldVenv\*" -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[$Tool] Warning: Could not fully remove old venv. Will overwrite with --clear."
            }
        }
    }
    if ($needsVenv) {
        Write-Host "[$Tool] Python venv not found, setting up..."
        $foundPy = Find-Python3
        if (-not $foundPy) {
            $msg = "No Python 3.10+ found. Install from https://python.org/downloads"
            Write-Host "[$Tool] ERROR: $msg"
            Write-Host "[$Tool] After installing, close and reopen your terminal, then run dg again."
            throw $msg
        }
        $pyVer = if ($foundPy -eq "py -3") { & py -3 --version 2>$null } else { & $foundPy --version 2>$null }
        Write-Host "[$Tool] Found $pyVer at $foundPy"

        $venvDir = Join-Path $DG "venv"
        if (Create-Venv $foundPy $venvDir) {
            Write-Host "[$Tool] Venv created."
        } else {
            $msg = "All venv creation methods failed (python=$foundPy). Install Python from https://python.org/downloads"
            Write-Host "[$Tool] ERROR: $msg"
            throw $msg
        }

        Write-Host "[$Tool] Installing Python dependencies..."
        $pip = Join-Path $venvDir "Scripts\pip.exe"
        $pipExit = Invoke-NativeQuiet $pip @("install", "mcp>=1.3.0", "uvicorn", "anyio", "starlette", "graperoot", "--quiet")
        if ($pipExit -ne 0) {
            Write-Host "[$Tool] Retrying pip install..."
            $pipExit = Invoke-NativeQuiet $pip @("install", "mcp>=1.3.0", "uvicorn", "anyio", "starlette", "graperoot", "--quiet", "--no-cache-dir")
        }
        if ($pipExit -ne 0) {
            $msg = "pip install failed (exit $pipExit)"
            throw $msg
        }
        Write-Host "[$Tool] Dependencies installed."
    }

    # Ensure pip/bin paths set even when venv already existed
    $pip = Join-Path $DG "venv\Scripts\pip.exe"
    $VenvBin = Join-Path $DG "venv\Scripts"

    # Auto-install compiled graperoot package (silent fallback to .py if it fails)
    $grapeOk = $false
    if ((Invoke-NativeQuiet $Python @("-c", "import graperoot")) -eq 0) {
        $grapeOk = $true
    } else {
        if ((Invoke-NativeQuiet $pip @("install", "graperoot", "--upgrade", "--quiet")) -eq 0) {
            $grapeOk = $true
        }
    }
    # Safety net: if graperoot still missing AND .py fallback files are gone, force reinstall
    if (-not $grapeOk) {
        $pyFallback = Join-Path $DG "graph_builder.py"
        if (-not (Test-Path $pyFallback)) {
            Write-Host "[$Tool] graperoot missing and no .py fallback -- retrying install..."
            if ((Invoke-NativeQuiet $pip @("install", "graperoot", "--upgrade", "--quiet", "--no-cache-dir")) -eq 0) {
                $grapeOk = $true
            } else {
                throw "graperoot install failed and no .py fallback available. Run: pip install graperoot"
            }
        }
    }
    # Remove conflicting dg.exe from Python Scripts (old graperoot installed it; renamed to dg-graph in 3.9.34+)
    try {
        $pipScripts = & $Python -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>$null
        if ($pipScripts) {
            $conflictDg = Join-Path $pipScripts "dg.exe"
            if (Test-Path $conflictDg) {
                Remove-Item $conflictDg -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}

    # Delete .py source files once compiled package confirmed working
    if ($grapeOk) {
        @("graph_builder.py", "dg.py", "mcp_graph_server.py", "context_packer.py", "dgc_claude.py") | ForEach-Object {
            Remove-Item (Join-Path $DG $_) -ErrorAction SilentlyContinue
        }
    }

    # ripgrep (rg) is required by the fallback_rg MCP tool  -  install if missing
    try {
        if (-not (Get-Command rg -ErrorAction SilentlyContinue)) {
            Write-Host "[$Tool] Installing ripgrep (required for code search)..."
            $rgInstalled = $false
            try {
                if (Get-Command winget -ErrorAction SilentlyContinue) {
                    $rgExit = Invoke-NativeQuiet "winget" @("install", "--id", "BurntSushi.ripgrep.MSVC", "-e", "--silent", "--accept-package-agreements", "--accept-source-agreements")
                    if ($rgExit -eq 0) { $rgInstalled = $true }
                }
                if (-not $rgInstalled -and (Get-Command choco -ErrorAction SilentlyContinue)) {
                    $rgExit = Invoke-NativeQuiet "choco" @("install", "ripgrep", "-y")
                    if ($rgExit -eq 0) { $rgInstalled = $true }
                }
                if (-not $rgInstalled -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
                    $rgExit = Invoke-NativeQuiet "scoop" @("install", "ripgrep")
                    if ($rgExit -eq 0) { $rgInstalled = $true }
                }
            } catch {}
            if (-not $rgInstalled -and -not (Get-Command rg -ErrorAction SilentlyContinue)) {
                Write-Host "[$Tool] WARNING: ripgrep (rg) not found  -  fallback_rg search may fail. Install: https://github.com/BurntSushi/ripgrep"
            }
        }
    } catch {
        Write-Host "[$Tool] WARNING: ripgrep auto-install failed ($($_.Exception.Message)). Install manually: https://github.com/BurntSushi/ripgrep"
    }

    # Use Get-Item to get the canonical Windows path with correct casing
    # (Resolve-Path preserves whatever casing the user typed, which can cause os error 123)
    # Fallback: GetUnresolvedProviderPathFromPSPath always returns a full path on PS5.1
    # when Get-Item/.FullName returns null (observed on some PS5 Windows environments).
    try {
        $resolvedProject = (Get-Item -LiteralPath (Resolve-Path -LiteralPath $ProjectPath).Path).FullName
    } catch {
        $resolvedProject = $null
    }
    if (-not $resolvedProject) {
        $resolvedProject = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath)
    }

    Write-Host ""
    Write-Host "[$Tool] If you receive any errors:"
    Write-Host "[$Tool]   1. Wait 5 minutes and run dg again"
    Write-Host "[$Tool]   2. Join Discord for help: https://discord.gg/rxgVVgCh"
    Write-Host ""

    $DataDir = Join-Path $resolvedProject ".dual-graph"
    $Gitignore = Join-Path $resolvedProject ".gitignore"

    if (Test-Path $Gitignore) {
        $content = Get-Content $Gitignore -ErrorAction SilentlyContinue
        if ($content -notcontains ".dual-graph/") {
            Add-Content -Path $Gitignore -Value ".dual-graph/"
            Write-Host "[$Tool] Added .dual-graph/ to .gitignore"
        }
    }

    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null }

    $scanErr = Join-Path $DataDir "scan_error.log"
    if (Test-Path $scanErr) { Remove-Item $scanErr -Force -ErrorAction SilentlyContinue }
    Write-Host "[$Tool] Project : $resolvedProject"
    Write-Host "[$Tool] Data    : $DataDir"
    Write-Host ""
    # Snapshot existing info_graph.json before rescan (fail-safe — never blocks scan)
    try { & $Python (Join-Path $PSScriptRoot "graph_snapshot.py") $DataDir "auto" 2>$null } catch {}

    Write-Host "[$Tool] Scanning project..."
    if ($grapeOk) {
        & (Join-Path $VenvBin "graph-builder.exe") --root $resolvedProject --out (Join-Path $DataDir "info_graph.json") 2> $scanErr
    } else {
        & $Python (Join-Path $DG "graph_builder.py") --root $resolvedProject --out (Join-Path $DataDir "info_graph.json") 2> $scanErr
    }
    if ($LASTEXITCODE -ne 0) {
        $tail = "no stderr captured"
        if (Test-Path $scanErr) {
            $tail = ((Get-Content $scanErr -Tail 20 -ErrorAction SilentlyContinue) -join " ") -replace '\s+', ' '
            if ($tail.Length -gt 700) { $tail = $tail.Substring(0, 700) }
        }
        throw "project scan failed"
    }
    if (Test-Path $scanErr) { Remove-Item $scanErr -Force -ErrorAction SilentlyContinue }
    Write-Host "[$Tool] Scan complete."
    Write-Host ""

    $pidFile = Join-Path $DataDir "mcp_server.pid"
    $portFile = Join-Path $DataDir "mcp_port"
    Stop-McpServer $pidFile $portFile

    $port = Get-FreePort
    Write-Host "[$Tool] Starting MCP server on port $port..."
    $log = Join-Path $DataDir "mcp_server.log"
    $errLog = Join-Path $DataDir "mcp_server.err.log"
    $env:DG_DATA_DIR = $DataDir
    $env:DUAL_GRAPH_PROJECT_ROOT = $resolvedProject
    $env:DG_BASE_URL = "http://localhost:$port"
    $env:DG_MCP_PORT = "$port"
    if ($grapeOk) {
        $server = Start-Process -FilePath (Join-Path $VenvBin "mcp-graph-server.exe") -RedirectStandardOutput $log -RedirectStandardError $errLog -WindowStyle Hidden -PassThru
    } else {
        $server = Start-Process -FilePath $Python -ArgumentList @((Join-Path $DG "mcp_graph_server.py")) -RedirectStandardOutput $log -RedirectStandardError $errLog -WindowStyle Hidden -PassThru
    }
    Set-Content -Path $pidFile -Value "$($server.Id)" -Encoding UTF8
    Set-Content -Path $portFile -Value "$port" -Encoding UTF8
    if (-not (Wait-Port -Port $port)) {
        # Auto-fix: kill stale process, pick new port, restart once
        Write-Host "[$Tool] MCP server did not start -- restarting on new port..."
        Stop-McpServer $pidFile $portFile
        $port = $port + 1
        $env:DG_BASE_URL = "http://localhost:$port"
        $env:DG_MCP_PORT = "$port"
        if ($grapeOk) {
            $server = Start-Process -FilePath (Join-Path $VenvBin "mcp-graph-server.exe") -RedirectStandardOutput $log -RedirectStandardError $errLog -WindowStyle Hidden -PassThru
        } else {
            $server = Start-Process -FilePath $Python -ArgumentList @((Join-Path $DG "mcp_graph_server.py")) -RedirectStandardOutput $log -RedirectStandardError $errLog -WindowStyle Hidden -PassThru
        }
        Set-Content -Path $pidFile -Value "$($server.Id)" -Encoding UTF8
        Set-Content -Path $portFile -Value "$port" -Encoding UTF8
        if (-not (Wait-Port -Port $port -Tries 15)) {
            Stop-McpServer $pidFile $portFile
            throw "MCP server did not start after retry"
        }
        Write-Host "[$Tool] MCP server recovered on port $port."
    }
    Write-Host "[$Tool] MCP server ready on port $port."
    Write-Host ""

    # Register MCP with Codex CLI (stdio bridge via mcp-remote)
    # Codex CLI only supports stdio MCP servers, so we use mcp-remote to bridge HTTP->stdio

    # Auto-install codex CLI if missing
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        Write-Host "[$Tool] codex CLI not found -- installing..."
        Invoke-NativeQuiet "npm" @("install", "-g", "@openai/codex") | Out-Null
        $env:PATH = "$env:PATH;$(npm config get prefix 2>$null)\node_modules\.bin"
        if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
            Stop-McpServer $pidFile $portFile
            Write-Host "[$Tool] ERROR: could not auto-install codex CLI."
            Write-Host "[$Tool]   npm install -g @openai/codex"
            exit 1
        }
        Write-Host "[$Tool] codex CLI installed."
    }

    # Auto-install mcp-remote if missing
    $npxCmd = (Get-Command npx.cmd -ErrorAction SilentlyContinue).Source
    if (-not $npxCmd) { $npxCmd = (Get-Command npx -ErrorAction SilentlyContinue).Source }
    if (-not $npxCmd) {
        Stop-McpServer $pidFile $portFile
        Write-Host "[$Tool] Error: npx not found. Install Node.js from https://nodejs.org"
        exit 1
    }
    if (-not (Get-Command mcp-remote -ErrorAction SilentlyContinue)) {
        Write-Host "[$Tool] mcp-remote not found -- installing..."
        Invoke-NativeQuiet "npm" @("install", "-g", "mcp-remote") | Out-Null
    }

    Invoke-NativeQuiet "codex" @("mcp", "remove", "dual-graph") | Out-Null
    $mcpAddExit = Invoke-NativeQuiet "codex" @("mcp", "add", "dual-graph", "--", $npxCmd, "mcp-remote", "http://localhost:$port/mcp", "--allow-http")
    # Fallback: try global mcp-remote
    if ($mcpAddExit -ne 0) {
        $mcpRemoteCmd = (Get-Command mcp-remote -ErrorAction SilentlyContinue).Source
        if ($mcpRemoteCmd) {
            $mcpAddExit = Invoke-NativeQuiet "codex" @("mcp", "add", "dual-graph", "--", $mcpRemoteCmd, "http://localhost:$port/mcp", "--allow-http")
        }
    }
    # Auto-fix: reinstall deps and retry
    if ($mcpAddExit -ne 0) {
        Write-Host "[$Tool] MCP registration failed -- reinstalling deps and retrying..."
        Invoke-NativeQuiet "npm" @("install", "-g", "@openai/codex", "mcp-remote") | Out-Null
        Invoke-NativeQuiet "codex" @("mcp", "remove", "dual-graph") | Out-Null
        $mcpAddExit = Invoke-NativeQuiet "codex" @("mcp", "add", "dual-graph", "--", $npxCmd, "mcp-remote", "http://localhost:$port/mcp", "--allow-http")
    }
    if ($mcpAddExit -ne 0) {
        Stop-McpServer $pidFile $portFile
        Write-Host "[$Tool] Error: failed to register MCP with codex after auto-fix."
        Write-Host "[$Tool] Manual fix:"
        Write-Host "[$Tool]   npm install -g @openai/codex mcp-remote"
        Write-Host "[$Tool]   Then run dg again."
        Write-Host "[$Tool] If it still fails, join Discord: https://discord.gg/rxgVVgCh"
        exit 1
    }
    Write-Host "[$Tool] MCP registered -> http://localhost:$port/mcp (via mcp-remote)"

    Write-Host ""
    Write-Host "[$Tool] Questions, bugs, or feedback? Join the community:"
    Write-Host "[$Tool]    https://discord.gg/rxgVVgCh"
    Write-Host ""
    Write-Host "[$Tool] Starting Codex CLI..."
    Write-Host ""

    Push-Location $resolvedProject
    Remove-Item Env:\DG_MCP_PORT -ErrorAction SilentlyContinue
    $hasNativePref = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePref) { $prevNativePref = $PSNativeCommandUseErrorActionPreference; $global:PSNativeCommandUseErrorActionPreference = $false }
    try {
        & codex
        $codexExit = $LASTEXITCODE
    } finally {
        Pop-Location
        if ($hasNativePref) { $global:PSNativeCommandUseErrorActionPreference = $prevNativePref }
    }

    Write-Host ""
    Write-Host "[$Tool] Cleaning up..."
    Invoke-NativeQuiet "codex" @("mcp", "remove", "dual-graph") | Out-Null
    Stop-McpServer $pidFile $portFile
    Write-Host "[$Tool] Done."
    exit $codexExit
} catch {
    $message = "$($_.Exception.Message)"
    Write-Host "[$Tool] Error: $message" -ForegroundColor Red
    exit 1
}
