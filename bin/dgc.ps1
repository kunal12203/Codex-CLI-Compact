# dgc - Claude Code + dual-graph MCP launcher (PowerShell)
# No param() block  - we parse $args manually to pass unknown flags through to claude.

$ErrorActionPreference = "Stop"

# Claude CLI flags  - three categories:
# 1. Single-value: always consume exactly the next argument
$_singleFlags = @('--agent','--agents','--append-system-prompt','--debug-file','--effort',
    '--fallback-model','--input-format','--json-schema','--max-budget-usd','--model',
    '--output-format','--permission-mode','--session-id','--setting-sources','--settings',
    '--system-prompt')
# 2. Optional-value: peek  - consume next arg only if it doesn't start with -
$_optionalFlags = @('--debug','--from-pr','--resume','--worktree')
# 3. Variadic: consume all following non-flag args (e.g. --allowedTools Bash Edit Read)
$_variadicFlags = @('--add-dir','--allowedTools','--allowed-tools','--betas',
    '--disallowedTools','--disallowed-tools','--file','--mcp-config','--plugin-dir','--tools')

$ProjectPath = ""
$_projectSet = $false
$Prompt = ""
$Resume = ""
$ClaudeExtraArgs = @()
$RuntimeToolNameRaw = "claude"

# -- Delegate to graperoot.ps1 for non-Claude tools ----------------------------
$_otherTools = @("--opencode","--cursor","--gemini","--copilot","--codex","--openclaw")
foreach ($a in $args) {
    if ($a -in $_otherTools) {
        $DG = Join-Path $env:USERPROFILE ".dual-graph"
        $GrapePs1 = Join-Path $DG "graperoot.ps1"
        # Force-download fresh graperoot.ps1 to ensure delegation works
        $GrapeR2 = "https://pub-18426978d5a14bf4a60ddedd7d5b6dab.r2.dev/graperoot.ps1"
        $GrapeGH = "https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main/bin/graperoot.ps1"
        try {
            $tmp = "$GrapePs1.tmp"
            Invoke-WebRequest $GrapeR2 -OutFile $tmp -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 1024) {
                Move-Item $tmp $GrapePs1 -Force
            }
        } catch {
            try {
                Invoke-WebRequest $GrapeGH -OutFile $tmp -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 1024) {
                    Move-Item $tmp $GrapePs1 -Force
                }
            } catch {}
        }
        Remove-Item "$GrapePs1.tmp" -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $GrapePs1)) {
            $GrapePs1 = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) "graperoot.ps1"
        }
        if (-not (Test-Path $GrapePs1)) {
            Write-Host "[dgc] ERROR: $a requires graperoot.ps1, which is missing."
            Write-Host "[dgc]   Run: irm https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main/install.ps1 | iex"
            exit 1
        }
        & $GrapePs1 @args
        exit $LASTEXITCODE
    }
}

$i = 0
while ($i -lt $args.Count) {
    $a = [string]$args[$i]
    if ($a -eq '--') {
        if ($i+1 -lt $args.Count) { $ClaudeExtraArgs += $args[($i+1)..($args.Count-1)] }
        break
    }
    elseif ($a -eq '-Resume') {
        # PowerShell-native convention: -Resume <id>
        $a = '--resume'
        # fall through to --flag handling below
    }
    if ($a -match '^-{1,2}toolname=(.*)$') {
        $RuntimeToolNameRaw = $Matches[1]
        $i++; continue
    }
    elseif ($a -in @('--toolname', '-toolname')) {
        if ($i + 1 -lt $args.Count -and -not ([string]$args[$i+1]).StartsWith('-')) {
            $RuntimeToolNameRaw = [string]$args[$i+1]
            $i += 2; continue
        }
        $RuntimeToolNameRaw = ""
        $i++; continue
    }
    if ($a -match '^--[^=]+=') {
        # --flag=value form (e.g. --tmux=classic)  - pass as-is
        $ClaudeExtraArgs += $a
        $i++; continue
    }
    elseif ($_singleFlags -contains $a) {
        $ClaudeExtraArgs += $a, [string]$args[$i+1]
        $i += 2; continue
    }
    elseif ($_optionalFlags -contains $a) {
        $ClaudeExtraArgs += $a
        $i++
        if ($i -lt $args.Count) {
            $peek = [string]$args[$i]
            if ($peek -and -not $peek.StartsWith('-')) {
                if ($a -eq '--resume') { $Resume = $peek }
                $ClaudeExtraArgs += $peek
                $i++
            }
        }
        continue
    }
    elseif ($_variadicFlags -contains $a) {
        $ClaudeExtraArgs += $a
        $i++
        while ($i -lt $args.Count) {
            $peek = [string]$args[$i]
            if ($peek.StartsWith('-')) { break }
            $ClaudeExtraArgs += $peek
            $i++
        }
        continue
    }
    elseif ($a.StartsWith('--') -or $a.StartsWith('-')) {
        # Unknown or boolean flag (--verbose, --brief, -p, -c, etc.)
        $ClaudeExtraArgs += $a
        $i++; continue
    }
    else {
        # Positional: first directory = project path, first non-dir = prompt
        if (-not $_projectSet -and (Test-Path $a -PathType Container -ErrorAction SilentlyContinue)) {
            $ProjectPath = $a; $_projectSet = $true
        } elseif (-not $Prompt) {
            $Prompt = $a
        } else {
            $ClaudeExtraArgs += $a
        }
        $i++; continue
    }
}
if (-not $_projectSet) { $ProjectPath = (Get-Location).Path }

$DG = Join-Path $env:USERPROFILE ".dual-graph"
$Tool = "dgc"
$PolicyMarker = "dgc-policy-v11"
$R2 = "https://pub-18426978d5a14bf4a60ddedd7d5b6dab.r2.dev"
$BaseUrl = "https://raw.githubusercontent.com/kunal12203/Codex-CLI-Compact/main"
$Python = Join-Path $DG "venv\Scripts\python.exe"
$NoticeFile = Join-Path $DG "last_update_notice.txt"
$WebhookUrl = "https://script.google.com/macros/s/AKfycbyq_5igbBUORhSqMNktAoX2GQg8BadKcYZOTV-XRUr3vbY3QuK7jjS8EWLg_pZyMDuD/exec"

function Normalize-ToolName([string]$Value) {
    $v = if ($Value) { $Value.Trim().ToLowerInvariant() } else { "" }
    if ($v -in @("claude", "codex", "graperoot")) { return $v }
    return "unknown"
}
$RuntimeToolName = Normalize-ToolName $RuntimeToolNameRaw
$env:DG_TOOLNAME = $RuntimeToolName

function Get-MachineId {
    $idFile = Join-Path $DG "identity.json"
    try {
        if (Test-Path $idFile) {
            $data = Get-Content $idFile -Raw | ConvertFrom-Json
            if ($data.machine_id) { return $data.machine_id }
        }
        $mid = [guid]::NewGuid().ToString("N")
        $payload = @{ machine_id = $mid; platform = "windows"; installed_date = (Get-Date -Format "yyyy-MM-dd"); tool = "launcher-auto" } | ConvertTo-Json -Compress
        if (-not (Test-Path $DG)) { New-Item -ItemType Directory -Force -Path $DG | Out-Null }
        [System.IO.File]::WriteAllText($idFile, $payload)
        return $mid
    } catch {
        return "unknown"
    }
}

function Get-TelemetryConsent {
    $idFile = Join-Path $DG "identity.json"
    try {
        if (Test-Path $idFile) {
            $data = Get-Content $idFile -Raw | ConvertFrom-Json
            if ($data.telemetry) { return $data.telemetry }
        }
    } catch {}
    return ""
}

function Set-TelemetryConsent([string]$Value) {
    $idFile = Join-Path $DG "identity.json"
    try {
        if (-not (Test-Path $DG)) { New-Item -ItemType Directory -Force -Path $DG | Out-Null }
        $data = @{}
        if (Test-Path $idFile) {
            try { $data = Get-Content $idFile -Raw | ConvertFrom-Json } catch {}
            # Convert PSObject to hashtable
            $ht = @{}; $data.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }; $data = $ht
        }
        $data["telemetry"] = $Value
        [System.IO.File]::WriteAllText($idFile, ($data | ConvertTo-Json -Compress))
    } catch {}
}

function Request-TelemetryConsent {
    $consent = Get-TelemetryConsent
    if ($consent -eq "enabled" -or $consent -eq "disabled") { return }
    Write-Host ""
    Write-Host "[$Tool] Help improve graperoot by sharing anonymous error reports?"
    Write-Host "[$Tool] This sends only error type and step (no code, paths, or personal data)."
    $answer = ""
    try { $answer = Read-Host "[$Tool] Enable telemetry? (y/n)" } catch { $answer = "" }
    if ($answer -match '^[Yy]') {
        Set-TelemetryConsent "enabled"
        Write-Host "[$Tool] Telemetry enabled. Thank you!"
    } else {
        Set-TelemetryConsent "disabled"
        Write-Host "[$Tool] Telemetry disabled. No data will be sent."
    }
    Write-Host ""
}

function Send-CliError([string]$Step, [string]$ErrorMessage) {
    try {
        if ((Get-TelemetryConsent) -ne "enabled") { return }
        $body = @{
            type = "cli_error"
            platform = "windows"
            machine_id = (Get-MachineId)
            error_message = $ErrorMessage
            script_step = $Step
            tool = $Tool
            toolname = $RuntimeToolName
        } | ConvertTo-Json -Compress
        Invoke-WebRequest -Uri $WebhookUrl -Method Post -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 3 | Out-Null
    } catch {}
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
            $listener = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
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

function To-ForwardSlashes([string]$Path) {
    return $Path -replace '\\', '/'
}

function Ensure-Line([string]$File, [string]$Line) {
    if (-not (Test-Path $File)) { return }
    $content = Get-Content $File -ErrorAction SilentlyContinue
    if ($content -notcontains $Line) {
        Add-Content -Path $File -Value $Line
        Write-Host "[$Tool] Added $Line to $(Split-Path $File -Leaf)"
    }
}

function Invoke-NativeQuiet([string]$FilePath, [string[]]$Arguments) {
    $hasNativePref = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePref) { $previousNativePref = $PSNativeCommandUseErrorActionPreference }
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        if ($hasNativePref) { $global:PSNativeCommandUseErrorActionPreference = $false }
        & $FilePath @Arguments > $null 2>&1
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
        if ($hasNativePref) { $global:PSNativeCommandUseErrorActionPreference = $previousNativePref }
    }
}

function Invoke-NativeCapture([string]$FilePath, [string[]]$Arguments) {
    $hasNativePref = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePref) { $previousNativePref = $PSNativeCommandUseErrorActionPreference }
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        if ($hasNativePref) { $global:PSNativeCommandUseErrorActionPreference = $false }
        return & $FilePath @Arguments 2>$null
    } finally {
        $ErrorActionPreference = $prevEAP
        if ($hasNativePref) { $global:PSNativeCommandUseErrorActionPreference = $previousNativePref }
    }
}

function Has-ClaudeMcp([string]$Name) {
    try {
        $list = Invoke-NativeCapture "claude" @("mcp", "list")
        if ($null -eq $list) { return $false }
        return ($list -join "`n") -match ("(?i)\b" + [regex]::Escape($Name) + "\b")
    } catch {
        return $false
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

function Remove-ClaudeMcpSafe([string]$Name, [string]$Scope = "") {
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Scope) {
            & claude mcp remove $Name --scope $Scope > $null 2>&1
        } else {
            & claude mcp remove $Name > $null 2>&1
        }
    } catch {
    } finally {
        $ErrorActionPreference = $oldPref
    }
}

function Find-Python3 {
    # 1. Try 'python3' (works on some Windows setups with alias)
    try {
        $p = (Get-Command python3 -ErrorAction SilentlyContinue).Source
        if ($p) {
            $ver = & python3 -c "import sys; print(sys.version_info >= (3, 10))" 2>$null
            if ($ver -eq "True") { return $p }
        }
    } catch {}

    # 2. Try 'python' (standard Windows name)
    try {
        $p = (Get-Command python -ErrorAction SilentlyContinue).Source
        if ($p -and $p -notmatch 'WindowsApps') {
            $ver = & python -c "import sys; print(sys.version_info >= (3, 10))" 2>$null
            if ($ver -eq "True") { return $p }
        }
    } catch {}

    # 3. Try 'py' launcher (Windows Python Launcher)
    try {
        $p = (Get-Command py -ErrorAction SilentlyContinue).Source
        if ($p) {
            $ver = & py -3 -c "import sys; print(sys.version_info >= (3, 10))" 2>$null
            if ($ver -eq "True") { return "py -3" }
        }
    } catch {}

    # 4. Common install paths
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

    # 5. Conda
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
    # Handle 'py -3' as a special case
    if ($PyExe -eq "py -3") {
        # Attempt 1: py -3 -m venv
        $exit = Invoke-NativeQuiet "py" @("-3", "-m", "venv", $VenvDir)
        if ($exit -eq 0 -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) { return $true }
        Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue

        # Attempt 2: py -3 -m venv --without-pip, then bootstrap
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

    # Attempt 1: standard venv (--clear overwrites any remnants from a locked dir)
    $exit = Invoke-NativeQuiet $PyExe @("-m", "venv", "--clear", $VenvDir)
    if ($exit -eq 0 -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) { return $true }
    cmd /c "rmdir /s /q `"$VenvDir`"" 2>$null
    Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue

    # Attempt 2: venv --without-pip + get-pip.py bootstrap
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

    # Attempt 3: virtualenv
    $exit = Invoke-NativeQuiet $PyExe @("-m", "virtualenv", $VenvDir)
    if ($exit -eq 0 -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) { return $true }
    Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue

    # Attempt 4: install virtualenv then use it
    Invoke-NativeQuiet $PyExe @("-m", "pip", "install", "--user", "virtualenv") | Out-Null
    $exit = Invoke-NativeQuiet $PyExe @("-m", "virtualenv", $VenvDir)
    if ($exit -eq 0 -and (Test-Path (Join-Path $VenvDir "Scripts\python.exe"))) { return $true }
    Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue

    return $false
}

try {
    if (-not (Test-Path $DG)) { New-Item -ItemType Directory -Force -Path $DG | Out-Null }

    # -- Telemetry opt-in (one-time prompt) --
    Request-TelemetryConsent

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
                $dgcPs1 = Join-Path $DG "dgc.ps1"
                if ((Test-Path $dgcPs1) -and (Get-Item $dgcPs1).Length -gt 1024) {
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
                $updatedScript = Join-Path $DG "dgc.ps1"
                if (Test-Path $updatedScript) {
                    $reArgs = @($ProjectPath)
                    if ($Prompt) { $reArgs += $Prompt }
                    $reArgs += $ClaudeExtraArgs
                    $reArgs += "--toolname"
                    $reArgs += $RuntimeToolName
                    & $updatedScript @reArgs; exit $LASTEXITCODE
                }
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
        # Also try taskkill as fallback (catches processes WMI might miss)
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
                # Last resort: remove what we can, then let --clear overwrite the rest
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
            Write-Host "[$Tool] After installing, close and reopen your terminal, then run dgc again."
            Send-CliError "Python setup" $msg
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
            Send-CliError "Venv creation" $msg
            throw $msg
        }

        Write-Host "[$Tool] Installing Python dependencies..."
        $pip = Join-Path $venvDir "Scripts\pip.exe"
        $pipExit = Invoke-NativeQuiet $pip @("install", "mcp>=1.3.0", "uvicorn", "anyio", "starlette", "graperoot", "--quiet")
        if ($pipExit -ne 0) {
            # Retry without cache
            Write-Host "[$Tool] Retrying pip install..."
            $pipExit = Invoke-NativeQuiet $pip @("install", "mcp>=1.3.0", "uvicorn", "anyio", "starlette", "graperoot", "--quiet", "--no-cache-dir")
        }
        if ($pipExit -ne 0) {
            $msg = "pip install failed (exit $pipExit)"
            Send-CliError "Pip install" $msg
            throw $msg
        }
        Write-Host "[$Tool] Dependencies installed."
    }

    # Ensure pip/bin paths set even when venv already existed
    $pip = Join-Path $DG "venv\Scripts\pip.exe"
    $VenvBin = Join-Path $DG "venv\Scripts"

    # Kill any previous MCP server BEFORE the graperoot upgrade.
    # pip upgrade replaces graph-builder.exe and mcp-graph-server.exe  -  if mcp-graph-server.exe
    # is still running, pip deletes graph-builder.exe (step 1) then hits WinError 32 on the
    # locked mcp-graph-server.exe (step 2), leaving graperoot half-uninstalled.
    # Use taskkill /F  -  it kills processes from other terminal sessions where Stop-Process
    # gets "Access Denied" because it only works on processes owned by the current session.
    $pidFile = Join-Path $DG "mcp_server.pid"
    $portFile = Join-Path $DG "mcp_port"
    if (Test-Path $pidFile) {
        try { Stop-Process -Id ([int](Get-Content $pidFile -Raw)) -Force -ErrorAction SilentlyContinue } catch {}
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    # taskkill /F works across sessions; Stop-Process is a fallback for non-Windows
    try { & taskkill /F /IM "mcp-graph-server.exe" /T 2>$null } catch {}
    try { & taskkill /F /IM "graph-builder.exe" /T 2>$null } catch {}
    # Also kill by port (catches renamed or custom server processes)
    try {
        Get-NetTCPConnection -LocalPort (8080..8099) -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object { try { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } catch {} }
    } catch {}
    Start-Sleep -Milliseconds 500

    # Auto-install compiled graperoot package (silent fallback to .py if it fails)
    $grapeOk = $false
    $grapeBuilderExe = Join-Path $VenvBin "graph-builder.exe"
    if ((Invoke-NativeQuiet $Python @("-c", "import graperoot.graph_builder")) -eq 0) {
        # graph_builder submodule is importable  -  also verify graph-builder.exe exists.
        # A partial pip upgrade deletes graph-builder.exe first, then fails on the locked
        # mcp-graph-server.exe, leaving graperoot importable but graph-builder.exe missing.
        if (Test-Path $grapeBuilderExe) {
            $grapeOk = $true
        } else {
            Write-Host "[$Tool] graperoot partially installed (graph-builder.exe missing) -- reinstalling..."
        }
    } elseif ((Invoke-NativeQuiet $Python @("-c", "import graperoot")) -eq 0) {
        # graperoot imports but graph_builder submodule is missing (broken sdist install)
        Write-Host "[$Tool] graperoot.graph_builder missing -- upgrading graperoot..."
    }
    if (-not $grapeOk) {
        if ((Invoke-NativeQuiet $pip @("install", "graperoot", "--upgrade", "--quiet")) -eq 0) {
            $grapeOk = (Test-Path $grapeBuilderExe)
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
                Send-CliError "Graperoot install" "graperoot install failed and no .py fallback available"
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

    # Validate project path exists before resolving
    if (-not (Test-Path -LiteralPath $ProjectPath)) {
        $msg = "Project path not found: $ProjectPath"
        Write-Host "[$Tool] ERROR: $msg" -ForegroundColor Red
        Write-Host "[$Tool] Check that the path exists and try again."
        Send-CliError "Project path" $msg
        Stop-McpServer $pidFile $portFile
        exit 1
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
    Write-Host "[$Tool]   1. Wait 5 minutes and run dgc again"
    Write-Host "[$Tool]   2. Update Claude Code: npm install -g @anthropic-ai/claude-code"
    Write-Host "[$Tool]   3. Join Discord for help: https://discord.gg/rxgVVgCh"
    Write-Host ""

    $DataDir = Join-Path $resolvedProject ".dual-graph"
    $DocFile = Join-Path $resolvedProject "CLAUDE.md"
    $Gitignore = Join-Path $resolvedProject ".gitignore"

    # (version check already ran at top of script -- just set forcePolicyWrite for CLAUDE.md)
    $forcePolicyWrite = $false
    $versionFile = Join-Path $DG "version.txt"
    $localVer = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { "0" }
    try {
        $remoteVer = Get-Text "$BaseUrl/bin/version.txt"
        if ($remoteVer -and ([version]$remoteVer -gt [version]$localVer)) { $forcePolicyWrite = $true }
    } catch {}

    if (Test-Path $Gitignore) { Ensure-Line $Gitignore ".dual-graph/" }

    $needWrite = $forcePolicyWrite -or -not (Test-Path $DocFile)
    if ((-not $needWrite) -and (Test-Path $DocFile)) {
        $needWrite = -not (Select-String -Path $DocFile -SimpleMatch $PolicyMarker -Quiet -ErrorAction SilentlyContinue)
    }

    if ($needWrite) {
        Write-Host "[$Tool] Writing CLAUDE.md policy..."
        $template = $null
        try { $template = Get-Text "$BaseUrl/CLAUDE.md.template" } catch {}
        if (-not $template) {
            # Hardcoded fallback  -  used when GitHub is unreachable (e.g. Cloudflare-blocking ISPs)
            $template = @"
<!-- $PolicyMarker -->
# Dual-Graph Context Policy

This project uses a local dual-graph MCP server for efficient context retrieval.

## MANDATORY: Adaptive graph_continue rule

**Call ``graph_continue`` ONLY when you do NOT already know the relevant files.**

### Call ``graph_continue`` when:
- This is the first message of a new task / conversation
- The task shifts to a completely different area of the codebase
- You need files you haven't read yet in this session

### SKIP ``graph_continue`` when:
- You already identified the relevant files earlier in this conversation
- You are doing follow-up work on files already read (verify, refactor, test, docs, cleanup, commit)
- The task is pure text (writing a commit message, summarising, explaining)

**If skipping, go directly to ``graph_read`` on the already-known ``file::symbol``.**

## When you DO call graph_continue

1. **If ``graph_continue`` returns ``needs_project=true``**: call ``graph_scan`` with ``pwd``. Do NOT ask the user.

2. **If ``graph_continue`` returns ``skip=true``**: fewer than 5 files  -  read only specifically named files.

3. **Read ``recommended_files``** using ``graph_read``.
   - Always use ``file::symbol`` notation (e.g. ``src/auth.ts::handleLogin``)  -  never read whole files.
   - ``recommended_files`` entries that already contain ``::`` must be passed verbatim.

4. **Obey confidence caps:**
   - ``confidence=high`` -> Stop. Do NOT grep or explore further.
   - ``confidence=medium`` -> ``fallback_rg`` at most ``max_supplementary_greps`` times, then ``graph_read`` at most ``max_supplementary_files`` more symbols. Stop.
   - ``confidence=low`` -> same as medium. Stop.

## Session State (compact, update after every turn)

Maintain a short JSON block in your working memory. Update it after each turn:

``````json
{
  "files_identified": ["path/to/file.py"],
  "symbols_changed": ["module::function"],
  "fix_applied": true,
  "features_added": ["description"],
  "open_issues": ["one-line note"]
}
``````

Use this state  -  not prose summaries  -  to remember what's been done across turns.

## Token Usage

A ``token-counter`` MCP is available for tracking live token usage.

- Before reading a large file: ``count_tokens({text: "<content>"})`` to check cost first.
- To show running session cost: ``get_session_stats()``
- To log completed task: ``log_usage({input_tokens: N, output_tokens: N, description: "task"})``

## Rules

- Do NOT use ``rg``, ``grep``, or bash file exploration before calling ``graph_continue`` (when required).
- Do NOT do broad/recursive exploration at any confidence level.
- ``max_supplementary_greps`` and ``max_supplementary_files`` are hard caps  -  never exceed them.
- Do NOT call ``graph_continue`` more than once per turn.
- Always use ``file::symbol`` notation with ``graph_read``  -  never bare filenames.
- After edits, call ``graph_register_edit`` with changed files using ``file::symbol`` notation.

## Context Store

Whenever you make a decision, identify a task, note a next step, fact, or blocker during a conversation, append it to ``.dual-graph/context-store.json``.

**Entry format:**
``````json
{"type": "decision|task|next|fact|blocker", "content": "one sentence max 15 words", "tags": ["topic"], "files": ["relevant/file.ts"], "date": "YYYY-MM-DD"}
``````

**To append:** Read the file -> add the new entry to the array -> Write it back -> call ``graph_register_edit`` on ``.dual-graph/context-store.json``.

**Rules:**
- Only log things worth remembering across sessions (not every minor detail)
- ``content`` must be under 15 words
- ``files`` lists the files this decision/task relates to (can be empty)
- Log immediately when the item arises  -  not at session end

## Session End

When the user signals they are done (e.g. "bye", "done", "wrap up", "end session"), proactively update ``CONTEXT.md`` in the project root with:
- **Current Task**: one sentence on what was being worked on
- **Key Decisions**: bullet list, max 3 items
- **Next Steps**: bullet list, max 3 items

Keep ``CONTEXT.md`` under 20 lines total. Do NOT summarize the full conversation  -  only what's needed to resume next session.
"@
        }
        Set-Content -Path $DocFile -Value $template -Encoding UTF8
        Write-Host "[$Tool] CLAUDE.md written."
    } else {
        Write-Host "[$Tool] CLAUDE.md already up to date, skipping."
    }

    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null }
    $contextStore = Join-Path $DataDir "context-store.json"
    if (-not (Test-Path $contextStore)) { [System.IO.File]::WriteAllText($contextStore, "[]") }

    $scanErr = Join-Path $DataDir "scan_error.log"
    if (Test-Path $scanErr) { Remove-Item $scanErr -Force -ErrorAction SilentlyContinue }
    Write-Host "[$Tool] Project : $resolvedProject"
    Write-Host "[$Tool] Data    : $DataDir"
    Write-Host ""
    # Use Continue for all native-command calls (graph-builder, mcp-graph-server, claude)
    # so that stderr output (tracebacks, npm notices) doesn't become a terminating error
    # under the global $ErrorActionPreference = "Stop".
    $prevEAPNative = $ErrorActionPreference; $ErrorActionPreference = "Continue"

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
        Send-CliError "Project scan" "project scan failed: $tail"
        throw "project scan failed"
    }
    if (Test-Path $scanErr) { Remove-Item $scanErr -Force -ErrorAction SilentlyContinue }
    Write-Host "[$Tool] Scan complete."
    Write-Host ""

    $pidFile = Join-Path $DataDir "mcp_server.pid"
    $portFile = Join-Path $DataDir "mcp_port"
    if (Test-Path $pidFile) {
        try {
            Stop-Process -Id ([int](Get-Content $pidFile -Raw)) -Force -ErrorAction SilentlyContinue
        } catch {}
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $portFile) {
        try {
            $oldPort = [int](Get-Content $portFile -Raw)
            Get-NetTCPConnection -LocalPort $oldPort -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess | ForEach-Object {
                Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        Remove-Item $portFile -Force -ErrorAction SilentlyContinue
    }

    # Kill any orphaned MCP server processes left by previous sessions.
    # taskkill /F works across terminal sessions; Stop-Process only works within same session.
    try { & taskkill /F /IM "mcp-graph-server.exe" /T 2>$null } catch {}
    try {
        Get-NetTCPConnection -LocalPort (8080..8099) -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object { try { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } catch {} }
    } catch {}

    $port = Get-FreePort
    Write-Host "[$Tool] Starting MCP server on port $port..."
    $log = Join-Path $DataDir "mcp_server.log"
    $errLog = Join-Path $DataDir "mcp_server.err.log"
    $env:DG_DATA_DIR = $DataDir
    $env:DUAL_GRAPH_PROJECT_ROOT = $resolvedProject
    $env:DG_BASE_URL = "http://127.0.0.1:$port"
    $env:DG_TOOLNAME = $RuntimeToolName
    $env:PORT = "$port"
    if ($grapeOk) {
        $server = Start-Process -FilePath (Join-Path $VenvBin "mcp-graph-server.exe") -RedirectStandardOutput $log -RedirectStandardError $errLog -WindowStyle Hidden -PassThru
    } else {
        $server = Start-Process -FilePath $Python -ArgumentList @((Join-Path $DG "mcp_graph_server.py")) -RedirectStandardOutput $log -RedirectStandardError $errLog -WindowStyle Hidden -PassThru
    }
    Set-Content -Path $pidFile -Value "$($server.Id)" -Encoding UTF8
    Set-Content -Path $portFile -Value "$port" -Encoding UTF8
    if (-not (Wait-Port -Port $port)) {
        Stop-McpServer $pidFile $portFile
        Send-CliError "MCP server" "MCP server did not start"
        throw "MCP server did not start"
    }
    Write-Host "[$Tool] MCP server ready on port $port."
    Write-Host ""

    # Pre-check: claude must be in PATH
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeCmd) {
        $msg = "Claude Code CLI not found in PATH. Install it with: npm install -g @anthropic-ai/claude-code"
        Write-Host "[$Tool] ERROR: $msg" -ForegroundColor Red
        Write-Host "[$Tool] After installing, close and reopen your terminal, then run dgc again."
        Send-CliError "Claude CLI" "Claude Code CLI not found in PATH"
        Stop-McpServer $pidFile $portFile
        exit 1
    }

    # PowerShell 7 can treat non-zero native exits as terminating errors.
    # Handle Claude CLI exits explicitly so "not found" on remove stays harmless.
    Remove-ClaudeMcpSafe "dual-graph"
    $mcpAddExit = Invoke-NativeQuiet "claude" @("mcp", "add", "--transport", "http", "dual-graph", "http://127.0.0.1:$port/mcp")
    if ($mcpAddExit -ne 0) {
        $mcpAddExit = Invoke-NativeQuiet "claude" @("mcp", "add", "--transport", "sse", "dual-graph", "http://127.0.0.1:$port/mcp")
    }
    if ($mcpAddExit -ne 0) {
        $mcpAddExit = Invoke-NativeQuiet "claude" @("mcp", "add", "dual-graph", "--url", "http://127.0.0.1:$port/mcp")
    }
    if ($mcpAddExit -ne 0) {
        Stop-McpServer $pidFile $portFile
        Write-Host "[$Tool] Error: failed to register MCP in Claude."
        Write-Host "[$Tool] Try this:"
        Write-Host "[$Tool] 1. Update Claude Code CLI:"
        Write-Host "[$Tool]    npm install -g @anthropic-ai/claude-code"
        Write-Host "[$Tool] 2. Wait 5 minutes and run dgc again."
        Write-Host "[$Tool] 3. If it still fails, open an issue on GitHub or join Discord:"
        Write-Host "[$Tool]    https://discord.gg/rxgVVgCh"
        Send-CliError "MCP registration" "failed to register MCP in Claude after auto-fix"
        exit 1
    }
    Write-Host "[$Tool] MCP registered -> http://127.0.0.1:$port/mcp"

    if (-not $env:DG_DISABLE_TOKEN_COUNTER) {
        # Wrap entirely so token-counter failures never kill the main launcher.
        # Use Continue so npm deprecation warnings on stderr don't become terminating errors.
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try {
            # Skip if token-counter is already registered (avoids disconnecting other terminals)
            $claudeJsonPath = Join-Path $env:USERPROFILE ".claude.json"
            if ((Test-Path $claudeJsonPath) -and (Select-String -Path $claudeJsonPath -Pattern '"token-counter"' -Quiet)) {
                $tcPortFile = Join-Path $env:USERPROFILE ".claude\token-counter\dashboard-port.txt"
                $tcPort = if (Test-Path $tcPortFile) { (Get-Content $tcPortFile -Raw).Trim() } else { "8899" }
                Write-Host "[$Tool] Token counter already registered -> http://127.0.0.1:$tcPort (global)"
            } else {
                $nodeCmd = (Get-Command node -ErrorAction SilentlyContinue).Source
                # Try npm.cmd (standard install), then npm (nvm-windows shim), then npx.
                $npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
                if (-not $npmCmd) { $npmCmd = (Get-Command npm -ErrorAction SilentlyContinue).Source }

                if ($nodeCmd -and $npmCmd) {
                    $tcDir = Join-Path $DG "tc"
                    $tcPkg = Join-Path $tcDir "node_modules\token-counter-mcp\package.json"
                    $tcMainCandidate = Join-Path $tcDir "node_modules\token-counter-mcp\dist\index.js"

                    # Check if install or update is needed.
                    $needsInstall = $false
                    if (-not (Test-Path $tcPkg) -or -not (Test-Path $tcMainCandidate)) {
                        $needsInstall = $true
                    } else {
                        # Check installed version against latest - update if outdated.
                        try {
                            $installedVer = (Get-Content $tcPkg -Raw | ConvertFrom-Json).version
                            $latestInfo = & $npmCmd view token-counter-mcp version 2>$null
                            if ($latestInfo -and $installedVer -and ($latestInfo.Trim() -ne $installedVer.Trim())) {
                                Write-Host "[$Tool] Token counter update available: $installedVer -> $($latestInfo.Trim())"
                                $needsInstall = $true
                            }
                        } catch {}  # version check is best-effort, never block
                    }

                    if ($needsInstall) {
                        Write-Host "[$Tool] Installing token-counter-mcp..."
                        New-Item -ItemType Directory -Force -Path $tcDir | Out-Null
                        # Write without BOM (ASCII-safe JSON) so npm parses it correctly on PS5.
                        [System.IO.File]::WriteAllText((Join-Path $tcDir "package.json"), '{"name":"tc-host","version":"1.0.0","private":true}')
                        $installExit = Invoke-NativeQuiet $npmCmd @("install", "--prefix", $tcDir, "--no-package-lock", "--no-fund", "--loglevel", "error", "token-counter-mcp@latest")
                        if ($installExit -ne 0) {
                            Write-Host "[$Tool] Token counter install failed (exit $installExit). Set DG_DISABLE_TOKEN_COUNTER=1 to silence."
                        }
                    }

                    # Resolve actual entry point from installed package.json.
                    $tcMain = $null
                    if (Test-Path $tcPkg) {
                        try {
                            $pkgData = Get-Content $tcPkg -Raw | ConvertFrom-Json
                            $pkgDir  = Split-Path $tcPkg
                            $bin = $pkgData.bin
                            if ($bin -is [string] -and $bin) {
                                $tcMain = Join-Path $pkgDir $bin
                            } elseif ($bin -and $bin.'token-counter-mcp') {
                                $tcMain = Join-Path $pkgDir $bin.'token-counter-mcp'
                            } elseif ($pkgData.main) {
                                $tcMain = Join-Path $pkgDir $pkgData.main
                            }
                        } catch {}
                    }
                    if ($tcMain -and (Test-Path $tcMain)) {
                        [void](Invoke-NativeQuiet "claude" @("mcp", "add", "--scope", "user", "token-counter", "--", $nodeCmd, $tcMain))
                        $tcPortFile = Join-Path $env:USERPROFILE ".claude\token-counter\dashboard-port.txt"
                        $tcPort = if (Test-Path $tcPortFile) { (Get-Content $tcPortFile -Raw).Trim() } else { "8899" }
                        Write-Host "[$Tool] Token counter -> http://127.0.0.1:$tcPort (global)"
                    } else {
                        Write-Host "[$Tool] Token counter skipped (entry file not found). Set DG_DISABLE_TOKEN_COUNTER=1 to silence."
                    }
                } else {
                    Write-Host "[$Tool] Token counter skipped (node/npm not found). Set DG_DISABLE_TOKEN_COUNTER=1 to silence."
                }
            }
        } catch {
            Write-Host "[$Tool] Token counter setup skipped: $($_.Exception.Message)"
        } finally {
            $ErrorActionPreference = $prevEAP
        }
    } else {
        Write-Host "[$Tool] Token counter disabled via DG_DISABLE_TOKEN_COUNTER=1"
    }

    # -- Clean up stale /bin/bash stop hook from old token-counter-mcp installs --
    $globalSettings = Join-Path $env:USERPROFILE ".claude\settings.json"
    if (Test-Path $globalSettings) {
        try {
            $gs = Get-Content $globalSettings -Raw | ConvertFrom-Json
            if ($gs.hooks -and $gs.hooks.Stop) {
                $cleaned = @($gs.hooks.Stop | Where-Object {
                    $dominated = $false
                    foreach ($h in $_.hooks) {
                        if ($h.command -match '/bin/bash|bash.*token-counter-stop\.sh') { $dominated = $true }
                    }
                    -not $dominated
                })
                if ($cleaned.Count -ne @($gs.hooks.Stop).Count) {
                    $gs.hooks.Stop = $cleaned
                    [System.IO.File]::WriteAllText($globalSettings, ($gs | ConvertTo-Json -Depth 8))
                    Write-Host "[$Tool] Removed stale /bin/bash stop hook from global settings"
                    # Also delete the old .sh file
                    $oldSh = Join-Path $env:USERPROFILE ".claude\token-counter-stop.sh"
                    if (Test-Path $oldSh) { Remove-Item $oldSh -Force -ErrorAction SilentlyContinue }
                }
            }
        } catch {}
    }

    $primePs1 = Join-Path $DataDir "prime.ps1"
    $stopPs1 = Join-Path $DataDir "stop_hook.ps1"
    $settingsDir = Join-Path $resolvedProject ".claude"
    $settingsFile = Join-Path $settingsDir "settings.local.json"

    @"
`$port = if (Test-Path '$portFile') { Get-Content '$portFile' } else { '$port' }
try {
    `$out = (Invoke-WebRequest "http://127.0.0.1:`$port/prime" -UseBasicParsing -TimeoutSec 3).Content
    if (`$out) { Write-Output `$out; Write-Error "[dual-graph] Context loaded (port `$port)" }
} catch {
    Write-Error "[dual-graph] MCP server not reachable on port `$port -- run dgc to restart"
}
`$ctxFile = '$resolvedProject\CONTEXT.md'
if (Test-Path `$ctxFile) { Write-Output ""; Write-Output "=== CONTEXT.md ==="; Get-Content `$ctxFile -Raw; Write-Output "=== end CONTEXT.md ===" }
`$storeFile = '$contextStore'
if (Test-Path `$storeFile) {
    `$cutoff = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd')
    try {
        `$entries = (Get-Content `$storeFile -Raw | ConvertFrom-Json) | Where-Object { `$_.date -ge `$cutoff } | Select-Object -First 15
        if (`$entries) { Write-Output ""; Write-Output "=== Stored Context ==="; `$entries | ForEach-Object { Write-Output ("[" + `$_.type + "] " + `$_.content) }; Write-Output "=== end Stored Context ===" }
    } catch {}
}
"@ | Set-Content -Path $primePs1 -Encoding UTF8

$stopTemplate = @'
$hookInput = [Console]::In.ReadToEnd()
try { $transcript = ($hookInput | ConvertFrom-Json).transcript_path } catch { $transcript = '' }
if ($transcript -and (Test-Path $transcript)) {
    try {
        # Track how many lines we already counted to avoid double-counting on resume
        $offsetFile = $transcript + ".stopoffset"
        $startLine = 0
        if (Test-Path $offsetFile) { try { $startLine = [int](Get-Content $offsetFile -Raw).Trim() } catch { $startLine = 0 } }
        $allLines = @(Get-Content $transcript)
        $inputTk = 0; $cacheCreate = 0; $cacheRead = 0; $outputTk = 0; $model = ''
        for ($i = $startLine; $i -lt $allLines.Count; $i++) {
            try {
                $msg = $allLines[$i] | ConvertFrom-Json -ErrorAction SilentlyContinue
                if (-not $msg -or $msg.type -ne 'assistant') { continue }
                $m = $msg.message
                if (-not $model -and $m.model) { $model = $m.model }
                $u = $m.usage
                if (-not $u) { continue }
                $inputTk   += [int]($u.input_tokens)
                $cacheCreate += [int]($u.cache_creation_input_tokens)
                $cacheRead += [int]($u.cache_read_input_tokens)
                $outputTk  += [int]($u.output_tokens)
            } catch { continue }
        }
        # Save current line count so next stop only counts new lines
        $allLines.Count.ToString() | Set-Content -Path $offsetFile -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($inputTk -gt 0 -or $cacheCreate -gt 0 -or $cacheRead -gt 0 -or $outputTk -gt 0) {
            if (-not $model) { $model = 'claude-sonnet-4-6' }
            $body = @{
                input_tokens = $inputTk
                output_tokens = $outputTk
                cache_creation_input_tokens = $cacheCreate
                cache_read_input_tokens = $cacheRead
                model = $model
                description = "auto"
                project = "__PROJECT__"
            } | ConvertTo-Json -Compress
            # POST to MCP graph server (always running, reliable)
            $mcpPortFile = Join-Path "__DATADIR__" "mcp_port"
            $mcpPort = if (Test-Path $mcpPortFile) { (Get-Content $mcpPortFile -Raw).Trim() } else { "8080" }
            Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$mcpPort/log" -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
            # Also POST to token-counter-mcp dashboard if available
            $portFile = Join-Path $env:USERPROFILE ".claude\token-counter\dashboard-port.txt"
            $dashPort = if (Test-Path $portFile) { (Get-Content $portFile -Raw).Trim() } else { "8899" }
            Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$dashPort/log" -ContentType 'application/json' -Body $body -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
}
'@
($stopTemplate.Replace("__PROJECT__", $resolvedProject).Replace("__DATADIR__", $DG)) | Set-Content -Path $stopPs1 -Encoding UTF8

    if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null }
    $primeCmd = 'powershell -NoProfile -File "' + (To-ForwardSlashes $primePs1) + '"'
    $stopCmd = 'powershell -NoProfile -File "' + (To-ForwardSlashes $stopPs1) + '"'
    $hooks = @{
        hooks = @{
            SessionStart = @(@{ matcher = ""; hooks = @(@{ type = "command"; command = $primeCmd }) })
            PreCompact   = @(@{ matcher = ""; hooks = @(@{ type = "command"; command = $primeCmd }) })
            Stop         = @(@{ matcher = ""; hooks = @(@{ type = "command"; command = $stopCmd }) })
        }
    }
    [System.IO.File]::WriteAllText($settingsFile, ($hooks | ConvertTo-Json -Depth 8))
    Write-Host "[$Tool] Context hooks ready (SessionStart + PreCompact + Stop)"

    # -- Leaderboard opt-in (one-time prompt) + token ping --
    $lbServer   = if ($env:DG_LICENSE_SERVER) { $env:DG_LICENSE_SERVER } else { "https://dual-graph-license-production.up.railway.app" }
    $lbOptFile  = Join-Path $DG "leaderboard_opted_in"
    $lbAliasFile = Join-Path $DG "leaderboard_alias"
    $lbMid      = Get-MachineId

    # One-time opt-in prompt (only if interactive and not yet decided)
    if (-not (Test-Path $lbOptFile) -and [Environment]::UserInteractive) {
        Write-Host ""
        Write-Host "[$Tool] Want to appear on the graperoot leaderboard?"
        Write-Host "[$Tool] It shows how many tokens you've used. Only your chosen name is shared."
        Write-Host "[$Tool] View: https://graperoot.dev/leaderboard"
        $lbAns = ""
        try { $lbAns = Read-Host "[$Tool] Opt in? (y/N)" } catch { $lbAns = "" }
        if ($lbAns -match '^[Yy]') {
            $lbName = ""
            try { $lbName = Read-Host "[$Tool] Display name (shown publicly)" } catch { $lbName = "" }
            if (-not $lbName) { $lbName = "anonymous" }
            [System.IO.File]::WriteAllText($lbOptFile, (ConvertTo-Json @{ opt_in = "yes"; alias = $lbName } -Compress))
            try {
                $body = ConvertTo-Json @{ machine_id = $lbMid; alias = $lbName; opt_in = $true } -Compress
                Invoke-WebRequest -Uri "$lbServer/set-alias" -Method Post -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 5 | Out-Null
            } catch {}
            Write-Host "[$Tool] You're on the leaderboard as '$lbName'!"
        } else {
            [System.IO.File]::WriteAllText($lbOptFile, (ConvertTo-Json @{ opt_in = "no" } -Compress))
            Write-Host "[$Tool] Skipped. Run 'dgc --leaderboard' anytime to opt in later."
        }
        Write-Host ""
    }

    # Re-send opt-in if locally saved but server may have missed it
    if (Test-Path $lbOptFile) {
        try {
            $lbData = Get-Content $lbOptFile -Raw | ConvertFrom-Json
            if ($lbData.opt_in -eq "yes" -and $lbMid) {
                $lbAlias = if ($lbData.alias) { $lbData.alias } else { "anonymous" }
                $body = ConvertTo-Json @{ machine_id = $lbMid; alias = $lbAlias; opt_in = $true } -Compress
                Start-Job -ScriptBlock {
                    param($uri, $b)
                    try { Invoke-WebRequest -Uri $uri -Method Post -Body $b -ContentType "application/json" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
                } -ArgumentList "$lbServer/set-alias", $body | Out-Null
            }
        } catch {}
    }

    # Token ping — read ~/.claude/token-counter/history.json (token-counter MCP's output)
    $tcHistoryFile = Join-Path $env:USERPROFILE ".claude\token-counter\history.json"
    if ($lbMid -and (Test-Path $tcHistoryFile)) {
        try {
            $entries = Get-Content $tcHistoryFile -Raw | ConvertFrom-Json
            if ($entries -is [array] -and $entries.Count -gt 0) {
                $totals = @{}
                foreach ($e in $entries) {
                    $m = ($e.model -or "").ToLower()
                    $mk = if ($m -match "opus") { "claude-opus" } elseif ($m -match "haiku") { "claude-haiku" } else { "claude-sonnet" }
                    if (-not $totals[$mk]) { $totals[$mk] = @{ input=0; output=0; cache_write=0; cache_read=0; cost_usd=0.0 } }
                    $totals[$mk].input       += [int]($e.inputTokens)
                    $totals[$mk].output      += [int]($e.outputTokens)
                    $totals[$mk].cache_write += [int]($e.cacheWriteTokens)
                    $totals[$mk].cache_read  += [int]($e.cacheReadTokens)
                    $totals[$mk].cost_usd    += [double]($e.totalCost)
                }
                $gi = 0; $go = 0; $gcw = 0; $gcr = 0; $gc = 0.0; $byModel = @{}
                foreach ($mk in $totals.Keys) {
                    $t = $totals[$mk]
                    $gi += $t.input; $go += $t.output; $gcw += $t.cache_write; $gcr += $t.cache_read; $gc += $t.cost_usd
                    $byModel[$mk] = @{ input_tokens=$t.input; output_tokens=$t.output; cache_write_tokens=$t.cache_write; cache_read_tokens=$t.cache_read; cost_usd=[math]::Round($t.cost_usd,6) }
                }
                if ($gi -gt 0) {
                    $tokenTotals = @{ input_tokens=$gi; output_tokens=$go; cache_write_tokens=$gcw; cache_read_tokens=$gcr; cost_usd=[math]::Round($gc,6); by_model=$byModel }
                    $pingBody = ConvertTo-Json @{ machine_id=$lbMid; platform="windows"; tool="dgc"; toolname=$RuntimeToolName; token_totals=$tokenTotals } -Compress -Depth 5
                    Start-Job -ScriptBlock {
                        try { Invoke-WebRequest -Uri "$using:lbServer/ping" -Method Post -Body $using:pingBody -ContentType "application/json" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
                    } | Out-Null
                }
            }
        } catch {}
    }
    # -------------------------------------------------------------------------

    Write-Host ""
    Write-Host "[$Tool] Starting claude..."
    Write-Host ""

    Push-Location $resolvedProject
    # Clear PORT so Claude and its MCP children (e.g. token-counter) don't inherit it.
    # Without this, token-counter reads PORT=8080, enters HTTP mode, and crashes with EADDRINUSE.
    Remove-Item Env:\PORT -ErrorAction SilentlyContinue
    $hasNativePref = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePref) { $prevNativePref = $PSNativeCommandUseErrorActionPreference; $global:PSNativeCommandUseErrorActionPreference = $false }
    try {
        $launchArgs = @()
        if ($Prompt) { $launchArgs += $Prompt }
        $launchArgs += $ClaudeExtraArgs
        & claude @launchArgs
        $claudeExit = $LASTEXITCODE
        # Show resume hint  -  filter by project to avoid showing wrong session
        try {
            $historyFile = Join-Path $env:USERPROFILE ".claude\history.jsonl"
            if (Test-Path $historyFile) {
                $normalizedProject = $resolvedProject.TrimEnd('\','/')
                $lastId = ""
                foreach ($line in [System.IO.File]::ReadAllLines($historyFile)) {
                    try {
                        $entry = $line | ConvertFrom-Json
                        $entryProject = $entry.project.TrimEnd('\','/')
                        if ($entryProject -eq $normalizedProject -and $entry.sessionId) {
                            $lastId = $entry.sessionId
                        }
                    } catch {}
                }
                if ($lastId) {
                    Write-Host ""
                    Write-Host "[$Tool] To resume this session with dual-graph:"
                    Write-Host "[$Tool]   dgc --resume `"$lastId`""
                }
            }
        } catch {}
    } finally {
        Pop-Location
        if ($hasNativePref) { $global:PSNativeCommandUseErrorActionPreference = $prevNativePref }
    }
    # Ignore normal user-initiated termination: SIGINT/Ctrl+C (130) and Windows CTRL_C_EVENT (-1073741510 / 0xC000013A)
    if ($claudeExit -ne 0 -and $claudeExit -ne 130 -and $claudeExit -ne -1073741510) {
        Send-CliError "Running Claude" "Claude exited with code $claudeExit in dgc.ps1"
    }

    # Restore strict error handling for cleanup
    $ErrorActionPreference = $prevEAPNative

    Write-Host ""
    Write-Host "[$Tool] Cleaning up..."
    Remove-ClaudeMcpSafe "dual-graph"
    # Token counter is global; do not remove it on exit.
    if (Test-Path $pidFile) {
        try { Stop-Process -Id ([int](Get-Content $pidFile -Raw)) -Force -ErrorAction SilentlyContinue } catch {}
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $portFile) {
        try {
            $killPort = [int](Get-Content $portFile -Raw)
            Get-NetTCPConnection -LocalPort $killPort -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess | ForEach-Object {
                Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        Remove-Item $portFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[$Tool] Done."
    exit $claudeExit
} catch {
    $message = "$($_.Exception.Message)"
    # Include script location if available for better diagnostics
    $location = if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { " [line $($_.InvocationInfo.ScriptLineNumber)]" } else { "" }
    $detail = "$message$location"
    if ($detail.Length -gt 700) { $detail = $detail.Substring(0, 700) }
    Send-CliError "Unhandled" $detail
    Write-Host "[$Tool] Error: $message" -ForegroundColor Red
    exit 1
}
