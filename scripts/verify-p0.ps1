<#
.SYNOPSIS
    DevRelay P0-01 / P0-02 / P0-03 verification harness.

.DESCRIPTION
    Repeatable, assertion-based verification of the Spec Kit -> Pi -> human-gate
    integration. It never mutates tracked files, never touches a production
    system, and confines every Spec Kit run state/session/log artefact to
    `.p0-evidence/` plus `.specify/workflows/runs/` (both git-ignored).

    P0-01  environment inventory + read-only Pi smoke run in an empty temp dir
    P0-02  Spec Kit `--integration pi` wiring + a read-only prompt step really
           dispatched to the local Pi CLI (model proven from the Pi session file)
    P0-03  two gate pauses and two resumes across separate OS processes,
           completed run, plus a reject path that must not walk past the gate

    Every assertion is printed and summarised; the script exits 1 if any check
    fails, so it is usable as a CI/regression gate before a Spec Kit or Pi
    upgrade is accepted.

.PARAMETER Phase
    all (default), p0-01, p0-02 or p0-03.

.PARAMETER EvidenceDir
    Where logs/session files are written. Default: <repo>\.p0-evidence

.PARAMETER NoPiSessionDir
    Do not inject `--session-dir` into the Pi invocation (used only to debug).

.NOTES
    Pi invocations are forced read-only with `--tools read,grep,find,ls` via
    SPECKIT_INTEGRATION_PI_EXTRA_ARGS, so no verification step can edit files
    even if the prompt asks for it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\verify-p0.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\verify-p0.ps1 -Phase p0-03
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'p0-01', 'p0-02', 'p0-03')]
    [string]$Phase = 'all',

    [string]$EvidenceDir = '',

    [string]$SpecInput = '实现用户向朋友转赠优惠券，一张券不能被重复领取',

    [string]$ProductAnswer = '产品经理确认（演示数据，2026-10-17）：转赠后原券立即冻结，原用户不可再用；仅指定接收人可领取；24 小时未领取自动退回原账户。',

    [switch]$NoPiSessionDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# Paths and environment discovery
# ---------------------------------------------------------------------------

$RepoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($EvidenceDir)) {
    $EvidenceDir = Join-Path $RepoRoot '.p0-evidence'
} elseif (-not [System.IO.Path]::IsPathRooted($EvidenceDir)) {
    $EvidenceDir = Join-Path $RepoRoot $EvidenceDir
}
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

function Resolve-SpecifyExe {
    if ($env:SPECIFY_BIN -and (Test-Path $env:SPECIFY_BIN)) { return $env:SPECIFY_BIN }
    $onPath = Get-Command specify -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $toolsRoot = if ($env:DEVRELAY_TOOLS_DIR) { $env:DEVRELAY_TOOLS_DIR } else { Join-Path $env:LOCALAPPDATA 'DevRelay\tools' }
    $candidates = @(Get-ChildItem -Path $toolsRoot -Directory -Filter 'specify-venv*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'Scripts\specify.exe' } |
        Where-Object { Test-Path $_ })
    if ($candidates.Count -gt 0) { return $candidates[0] }
    throw "specify CLI not found. Run scripts\setup-specify.ps1 first, or set `$env:SPECIFY_BIN."
}

$SpecifyExe = Resolve-SpecifyExe
$PiExe = (Get-Command pi -ErrorAction SilentlyContinue).Source
$script:Results = New-Object System.Collections.ArrayList
$script:P02Model = $null
$script:P03RunId = $null

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Add-Check {
    param([string]$Id, [string]$Title, [string]$Status, [string]$Detail = '')
    [void]$script:Results.Add([pscustomobject]@{ Id = $Id; Title = $Title; Status = $Status; Detail = $Detail })
    $color = @{ passed = 'Green'; failed = 'Red'; not_run = 'Yellow' }[$Status]
    Write-Host ("  [{0,-7}] {1} :: {2}" -f $Status.ToUpperInvariant(), $Id, $Title) -ForegroundColor $color
    if ($Detail) { Write-Host ("            {0}" -f $Detail) -ForegroundColor DarkGray }
}

function Test-Check {
    param([string]$Id, [string]$Title, [scriptblock]$Body)
    try {
        $detail = & $Body
        if ($null -eq $detail) { $detail = '' }
        Add-Check -Id $Id -Title $Title -Status 'passed' -Detail ([string]$detail)
    } catch {
        Add-Check -Id $Id -Title $Title -Status 'failed' -Detail $_.Exception.Message
    }
}

function Quote-Arg {
    param([string]$Argument)
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-Native {
    <#
        Runs a native executable with a CLOSED stdin pipe.

        The closed pipe is deliberate: a `gate` step pauses only when
        `sys.stdin.isatty()` is false. Windows' NUL device is a character device,
        so `< NUL` still reports isatty() == true and the gate would fall through
        to its interactive prompt, read EOF, and auto-reject the run.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $RepoRoot,
        [int]$TimeoutSeconds = 900,
        [hashtable]$EnvironmentOverrides = @{}
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    foreach ($key in $EnvironmentOverrides.Keys) { $psi.EnvironmentVariables[$key] = $EnvironmentOverrides[$key] }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        throw "Timeout after ${TimeoutSeconds}s: $FilePath $($psi.Arguments)"
    }
    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdoutTask.Result
        StdErr   = $stderrTask.Result
        Command  = "$FilePath $($psi.Arguments)"
    }
}

function Invoke-Specify {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 900)
    $overrides = @{}
    if ($script:PiExtraArgs) { $overrides['SPECKIT_INTEGRATION_PI_EXTRA_ARGS'] = $script:PiExtraArgs }
    Invoke-Native -FilePath $SpecifyExe -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds -EnvironmentOverrides $overrides
}

function ConvertFrom-SpecifyJson {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Context)
    $trimmed = $Text.Trim()
    if (-not $trimmed) { throw "$Context produced no stdout" }
    try { return $trimmed | ConvertFrom-Json } catch { throw "$Context stdout is not JSON: $trimmed" }
}

function Save-Evidence {
    param([string]$Name, [string]$Content)
    $path = Join-Path $EvidenceDir $Name
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding $false))
    return $path
}

function Read-JsonFile {
    param([string]$Path)
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    return $raw | ConvertFrom-Json
}

function Get-RunDir {
    param([string]$RunId)
    return Join-Path $RepoRoot ".specify\workflows\runs\$RunId"
}

function Get-PiSessionModel {
    <#
        Returns the provider/model Pi actually used, read from the Pi session
        JSONL (`model_change` event) rather than trusting a config value.
    #>
    param([string]$SessionDir)
    if (-not (Test-Path $SessionDir)) { throw "no Pi session dir at $SessionDir (Pi may not have been invoked)" }
    $files = @(Get-ChildItem -Path $SessionDir -Recurse -Filter '*.jsonl' | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { throw "no Pi session file in $SessionDir" }
    $line = Get-Content -Path $files[0].FullName -Encoding UTF8 |
        Where-Object { $_ -like '*"model_change"*' } | Select-Object -First 1
    if (-not $line) { throw "session $($files[0].Name) has no model_change event" }
    $evt = $line | ConvertFrom-Json
    return [pscustomobject]@{ Provider = $evt.provider; ModelId = $evt.modelId; SessionFile = $files[0].FullName }
}

function Read-LogEvents {
    param([string]$RunId)
    $logPath = Join-Path (Get-RunDir $RunId) 'log.jsonl'
    if (-not (Test-Path $logPath)) { throw "missing log.jsonl for run $RunId" }
    return @(Get-Content -Path $logPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

# ---------------------------------------------------------------------------
# Pi invocation policy for this harness: read-only tools + isolated sessions
# ---------------------------------------------------------------------------

# The Pi session dir is the only reliable place that records the model actually
# used (Spec Kit stores `model: null` unless the workflow pins one).
$script:PiExtraArgs = '--tools read,grep,find,ls'
if (-not $NoPiSessionDir) {
    $sessionRoot = Join-Path $EvidenceDir 'pi-sessions'
    New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null
    $script:PiExtraArgs = "$script:PiExtraArgs --session-dir `"$sessionRoot`""
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' DevRelay P0-01/P0-02/P0-03 verification' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host " repo        : $RepoRoot"
Write-Host " specify     : $SpecifyExe"
Write-Host " pi          : $PiExe"
Write-Host " evidence    : $EvidenceDir"
Write-Host " phase       : $Phase"
Write-Host " pi extra    : $script:PiExtraArgs"
Write-Host ''

$runP01 = $Phase -in @('all', 'p0-01')
$runP02 = $Phase -in @('all', 'p0-02')
$runP03 = $Phase -in @('all', 'p0-03')

# ===========================================================================
# P0-01  environment inventory
# ===========================================================================
if ($runP01) {
    Write-Host '--- P0-01 environment inventory ---------------------------------' -ForegroundColor Cyan

    $versions = [ordered]@{
        recorded_at   = (Get-Date).ToString('o')
        os            = [System.Environment]::OSVersion.VersionString
        powershell    = $PSVersionTable.PSVersion.ToString()
        node          = (& node --version 2>&1 | Out-String).Trim()
        npm           = (& npm --version 2>&1 | Out-String).Trim()
        pi            = (& pi --version 2>&1 | Out-String).Trim()
        python        = (& python --version 2>&1 | Out-String).Trim()
        git           = (& git --version 2>&1 | Out-String).Trim()
        specify       = ((& $SpecifyExe version 2>&1 | Out-String) -replace '(?s).*CLI Version\s+(\S+).*', '$1').Trim()
        specify_path  = $SpecifyExe
        pi_path       = $PiExe
        pi_package    = $(if (Test-Path (Join-Path (Split-Path $PiExe -Parent) 'package.json')) { (Read-JsonFile (Join-Path (Split-Path $PiExe -Parent) 'package.json')).name } else { 'unknown' })
    }
    $versions.specify_full = (& $SpecifyExe version 2>&1 | Out-String)
    $versions.pi_help = (& pi --help 2>&1 | Out-String)
    $versions.specify_workflow_help = (& $SpecifyExe workflow --help 2>&1 | Out-String)
    $versions.specify_integration_status = (& $SpecifyExe integration status 2>&1 | Out-String)
    $versions.git_status = (& git -C $RepoRoot status --short 2>&1 | Out-String)

    # Never persist credentials: `pi auth check --json` without --credentials
    # only reports readiness.
    $piSettingsPath = Join-Path $env:USERPROFILE '.pi\agent\settings.json'
    if (Test-Path $piSettingsPath) {
        $piSettings = Read-JsonFile $piSettingsPath
        $versions.pi_default_provider = $piSettings.defaultProvider
        $versions.pi_default_model = $piSettings.defaultModel
        $versions.pi_auth = (& pi auth check --provider $piSettings.defaultProvider --json 2>&1 | Out-String).Trim()
    }

    $versionsYaml = ($versions.GetEnumerator() | ForEach-Object { "$($_.Key): |`n" + (($_.Value -split "`r?`n") -join "`n  ") }) -join "`n"
    $envEvidence = Save-Evidence -Name 'p0-01\environment.txt' -Content $versionsYaml
    Write-Host "  evidence: $envEvidence"

    Test-Check 'P0-01-01' 'Node.js >= 22 (Pi CLI requirement)' {
        $major = [int]((& node --version).TrimStart('v').Split('.')[0])
        if ($major -lt 22) { throw "node major $major < 22" }
        "node $(& node --version)"
    }

    Test-Check 'P0-01-02' 'Python >= 3.11 (Spec Kit requirement)' {
        $v = (& python -c "import sys;print('%d.%d.%d' % sys.version_info[:3])").Trim()
        if ([version]$v -lt [version]'3.11') { throw "python $v < 3.11" }
        "python $v"
    }

    Test-Check 'P0-01-03' 'Pi CLI present and reports a version' {
        $v = (& pi --version 2>&1 | Out-String).Trim()
        if ($v -notmatch '^\d+\.\d+\.\d+') { throw "unexpected pi --version output: $v" }
        "pi $v (package $($versions.pi_package))"
    }

    Test-Check 'P0-01-04' 'Spec Kit CLI present and reports a version' {
        if ([string]::IsNullOrWhiteSpace($versions.specify)) { throw "could not parse specify version; see $envEvidence" }
        "specify $($versions.specify)"
    }

    Test-Check 'P0-01-05' 'Pi DeepSeek credentials are ready (no secret recorded)' {
        if ($versions.pi_auth -notmatch '"status"\s*:\s*"ready"') { throw "pi auth check not ready: $($versions.pi_auth)" }
        $versions.pi_auth
    }

    Test-Check 'P0-01-06' 'Pi answers a read-only question in an empty temp dir without creating files' {
        $tmp = Join-Path $env:TEMP ("devrelay-p0-01-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $before = @(Get-ChildItem -Path $tmp -Force).Count
            $res = Invoke-Native -FilePath $PiExe -WorkingDirectory $tmp -TimeoutSeconds 300 -Arguments @(
                '-p', '--no-session', '--tools', 'read,grep,find,ls',
                '只回答一句话，不创建、不修改、不删除任何文件：需求不明确时应该先做什么？'
            )
            $after = @(Get-ChildItem -Path $tmp -Force).Count
            Save-Evidence -Name 'p0-01\pi-empty-dir-smoke.txt' -Content ($res.Command + "`n--- exit: " + $res.ExitCode + "`n--- stdout ---`n" + $res.StdOut + "`n--- stderr ---`n" + $res.StdErr) | Out-Null
            if ($res.ExitCode -ne 0) { throw "pi exited $($res.ExitCode): $($res.StdErr)" }
            if ([string]::IsNullOrWhiteSpace($res.StdOut)) { throw 'pi produced no output' }
            if ($before -ne $after) { throw "temp dir changed: $before -> $after entries" }
            "exit 0, $($res.StdOut.Trim().Length) chars, 0 files created in $tmp"
        } finally {
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Check 'P0-01-07' 'No tracked file was modified by the inventory' {
        $dirty = (& git -C $RepoRoot status --porcelain 2>&1 | Out-String).Trim()
        $modified = @($dirty -split "`n" | Where-Object { $_ -match '^\s*(M|A|D|R)\s' })
        if ($modified.Count -gt 0) { throw "tracked changes present: $($modified -join '; ')" }
        'working tree has no staged/modified tracked files'
    }
}

# ===========================================================================
# P0-02  Spec Kit -> Pi native integration
# ===========================================================================
if ($runP02) {
    Write-Host ''
    Write-Host '--- P0-02 Spec Kit -> Pi integration ----------------------------' -ForegroundColor Cyan

    Test-Check 'P0-02-01' '`specify integration status` reports pi as the default integration' {
        $status = (& $SpecifyExe integration status 2>&1 | Out-String)
        Save-Evidence -Name 'p0-02\integration-status.txt' -Content $status | Out-Null
        if ($status -notmatch 'Default integration:\s*pi') { throw "default integration is not pi:`n$status" }
        'Default integration: pi, multi-install safe'
    }

    Test-Check 'P0-02-02' 'Pi prompt templates were installed into .pi/prompts' {
        $dir = Join-Path $RepoRoot '.pi\prompts'
        if (-not (Test-Path $dir)) { throw '.pi/prompts missing' }
        $files = @(Get-ChildItem $dir -Filter '*.md')
        if ($files.Count -lt 5) { throw "only $($files.Count) command templates found" }
        "$($files.Count) templates: $(($files.Name | Sort-Object) -join ', ')"
    }

    Test-Check 'P0-02-03' 'A workflow `prompt` step really dispatches to the local Pi CLI' {
        $res = Invoke-Specify -Arguments @('workflow', 'run', '.\workflows\p0-02-pi-probe.yml', '--input', "spec=$SpecInput", '--json') -TimeoutSeconds 600
        Save-Evidence -Name 'p0-02\probe-run.txt' -Content ($res.Command + "`n--- exit: " + $res.ExitCode + "`n--- stdout ---`n" + $res.StdOut + "`n--- stderr ---`n" + $res.StdErr) | Out-Null
        $json = ConvertFrom-SpecifyJson -Text $res.StdOut -Context 'p0-02 probe run'
        if ($res.ExitCode -ne 0) { throw "exit $($res.ExitCode)" }
        if ($json.status -ne 'completed') { throw "status=$($json.status) run=$($json.run_id)" }
        $state = Read-JsonFile (Join-Path (Get-RunDir $json.run_id) 'state.json')
        $step = $state.step_results.read_only_probe
        if (-not $step.output.dispatched) { throw 'step output says dispatched=false' }
        $script:P02RunId = $json.run_id
        "run $($json.run_id) completed in a fresh process; dispatched=$($step.output.dispatched) exit_code=$($step.output.exit_code)"
    }

    Test-Check 'P0-02-04' 'Pi recorded which model it actually used (session evidence)' {
        $model = Get-PiSessionModel -SessionDir (Join-Path $EvidenceDir 'pi-sessions')
        $script:P02Model = "$($model.Provider)/$($model.ModelId)"
        if (-not $model.Provider -or -not $model.ModelId) { throw 'model_change event incomplete' }
        "$script:P02Model (from $(Split-Path $model.SessionFile -Leaf))"
    }

    Test-Check 'P0-02-05' 'The workflow file, not a human, carried the prompt (no manual copy/paste)' {
        $wf = Get-Content (Join-Path $RepoRoot 'workflows\p0-02-pi-probe.yml') -Raw -Encoding UTF8
        if ($wf -notmatch 'type:\s*prompt') { throw 'probe workflow has no prompt step' }
        if ($wf -notmatch 'integration:\s*pi') { throw 'probe step does not pin integration: pi' }
        'workflow declares `type: prompt` + `integration: pi`; the harness never feeds prompt text into an interactive Pi session'
    }

    Test-Check 'P0-02-06' '`capture: true` returns Pi agent text into steps.<id>.output.stdout' {
        $res = Invoke-Specify -Arguments @('workflow', 'run', '.\workflows\p0-02-capture-probe.yml', '--json') -TimeoutSeconds 300
        Save-Evidence -Name 'p0-02\capture-probe.txt' -Content ($res.Command + "`n--- exit: " + $res.ExitCode + "`n--- stdout ---`n" + $res.StdOut + "`n--- stderr ---`n" + $res.StdErr) | Out-Null
        $json = ConvertFrom-SpecifyJson -Text $res.StdOut -Context 'p0-02 capture probe'
        if ($res.ExitCode -ne 0) { throw "exit $($res.ExitCode)" }
        if ($json.status -ne 'completed') { throw "expected completed, got $($json.status): $($json.error)" }
        $state = Read-JsonFile (Join-Path (Get-RunDir $json.run_id) 'state.json')
        $out = $state.step_results.capture_probe.output
        $text = ([string]$out.stdout).Trim()
        if ($text -notmatch 'OK') { throw "captured stdout does not contain OK: '$text'" }
        if ($out.stdout_truncated -or $out.timed_out) { throw 'capture reported truncation/timeout' }
        "run $($json.run_id) captured $($text.Length) chars of agent text: '$text'"
    }
}

# ===========================================================================
# P0-03  gate pause / resume across separate processes
# ===========================================================================
if ($runP03) {
    Write-Host ''
    Write-Host '--- P0-03 gate pause / resume -----------------------------------' -ForegroundColor Cyan

    $smoke = '.\DevRelay_v0.1_smoke_workflow.yml'
    $runId = $null
    $phaseLog = New-Object System.Text.StringBuilder

    Test-Check 'P0-03-01' 'Smoke workflow parses against the installed Spec Kit version' {
        $res = Invoke-Specify -Arguments @('workflow', 'info', $smoke)
        Save-Evidence -Name 'p0-03\workflow-info.txt' -Content (& $SpecifyExe workflow info $smoke 2>&1 | Out-String) | Out-Null
        (($res.StdOut -split "`n") | Where-Object { $_ -match 'Steps \(|→' } | ForEach-Object { $_.Trim() }) -join ' | '
    }

    Test-Check 'P0-03-02' 'Phase 1 (process A): run pauses at question_gate' {
        $res = Invoke-Specify -Arguments @('workflow', 'run', $smoke, '--input', "spec=$SpecInput", '--json') -TimeoutSeconds 900
        [void]$phaseLog.AppendLine('### phase1 run (exit ' + $res.ExitCode + ')')
        [void]$phaseLog.AppendLine($res.StdOut)
        [void]$phaseLog.AppendLine('--- pi output (stderr) ---')
        [void]$phaseLog.AppendLine($res.StdErr)
        Save-Evidence -Name 'p0-03\phase1-run.txt' -Content $phaseLog.ToString() | Out-Null
        $json = ConvertFrom-SpecifyJson -Text $res.StdOut -Context 'p0-03 run'
        if ($json.status -ne 'paused') { throw "expected paused, got $($json.status): $($json.error)" }
        if ($json.current_step_id -ne 'question_gate') { throw "paused at $($json.current_step_id), expected question_gate" }
        $script:P03RunId = $json.run_id
        "run $($json.run_id) status=paused at $($json.current_step_id) (gate choice=$($json.gate.choice))"
    }

    $runId = $script:P03RunId
    if (-not $runId) { Add-Check 'P0-03-03' 'Phase 2/3 (cannot continue without a paused run)' 'not_run' 'phase 1 did not produce a paused run'; $runId = $null }

    if ($runId) {
        Test-Check 'P0-03-03' 'Phase 2 (process B): resume with the product answer pauses at decision_gate' {
            $res = Invoke-Specify -Arguments @('workflow', 'resume', $runId, '--input', 'question_verdict=approve', '--input', "product_answer=$ProductAnswer", '--json') -TimeoutSeconds 900
            Save-Evidence -Name 'p0-03\phase2-resume.txt' -Content ("### phase2 resume (exit $($res.ExitCode))`n" + $res.StdOut + "`n--- pi output (stderr) ---`n" + $res.StdErr) | Out-Null
            $json = ConvertFrom-SpecifyJson -Text $res.StdOut -Context 'p0-03 resume 1'
            if ($json.status -ne 'paused') { throw "expected paused, got $($json.status): $($json.error)" }
            if ($json.current_step_id -ne 'decision_gate') { throw "paused at $($json.current_step_id), expected decision_gate" }
            "same run resumed in a new process -> status=paused at $($json.current_step_id)"
        }

        Test-Check 'P0-03-04' 'Phase 3 (process C): resume with decision=A completes the run' {
            $res = Invoke-Specify -Arguments @('workflow', 'resume', $runId, '--input', 'decision_verdict=A', '--json') -TimeoutSeconds 900
            Save-Evidence -Name 'p0-03\phase3-resume.txt' -Content ("### phase3 resume (exit $($res.ExitCode))`n" + $res.StdOut + "`n--- pi output (stderr) ---`n" + $res.StdErr) | Out-Null
            $json = ConvertFrom-SpecifyJson -Text $res.StdOut -Context 'p0-03 resume 2'
            if ($res.ExitCode -ne 0) { throw "exit $($res.ExitCode)" }
            if ($json.status -ne 'completed') { throw "expected completed, got $($json.status): $($json.error)" }
            'status=completed'
        }

        Test-Check 'P0-03-05' 'All five steps completed and run state persisted under .specify/workflows/runs' {
            $statusRes = Invoke-Specify -Arguments @('workflow', 'status', $runId, '--json')
            Save-Evidence -Name 'p0-03\final-status.txt' -Content $statusRes.StdOut | Out-Null
            $json = ConvertFrom-SpecifyJson -Text $statusRes.StdOut -Context 'p0-03 status'
            $expected = @('identify_business_gap', 'question_gate', 'propose_architecture', 'decision_gate', 'report_choice')
            foreach ($step in $expected) {
                $actual = $json.steps.$step
                if ($actual -ne 'completed') { throw "step $step is $actual, expected completed" }
            }
            if (-not (Test-Path (Join-Path (Get-RunDir $runId) 'state.json'))) { throw 'state.json missing' }
            '5/5 completed; state.json + inputs.json + log.jsonl present in ' + (Get-RunDir $runId)
        }

        Test-Check 'P0-03-06' 'Completed steps were not re-executed on resume (replay only)' {
            $events = Read-LogEvents -RunId $runId
            $starts = @($events | Where-Object { $_.event -eq 'step_started' -and $_.step_id -eq 'identify_business_gap' }).Count
            $archStarts = @($events | Where-Object { $_.event -eq 'step_started' -and $_.step_id -eq 'propose_architecture' }).Count
            $gateStarts = @($events | Where-Object { $_.event -eq 'step_started' -and $_.step_id -eq 'question_gate' }).Count
            if ($starts -ne 1) { throw "identify_business_gap started $starts times, expected exactly 1" }
            if ($archStarts -ne 1) { throw "propose_architecture started $archStarts times, expected exactly 1 (only after gate 1 approval)" }
            if ($gateStarts -ne 2) { throw "question_gate started $gateStarts times, expected 2 (pause + verdict consume)" }
            "identify_business_gap=1 start, propose_architecture=1 start, question_gate=2 starts (pause then verdict)"
        }

        Test-Check 'P0-03-07' 'Gate output is available to later steps ({{ steps.decision_gate.output.choice }})' {
            $state = Read-JsonFile (Join-Path (Get-RunDir $runId) 'state.json')
            $choice = $state.step_results.decision_gate.output.choice
            if ($choice -ne 'A') { throw "decision_gate.output.choice = '$choice', expected A" }
            $prompt = $state.step_results.report_choice.output.prompt
            if ($prompt -notmatch '人类选择的技术方案为 A') { throw "report_choice prompt did not receive the human choice: $prompt" }
            'report_choice prompt interpolated the recorded human verdict A'
        }
    }

    Test-Check 'P0-03-08' 'Reject path: a rejected gate aborts and does not walk past the review' {
        $res = Invoke-Specify -Arguments @('workflow', 'run', $smoke, '--input', 'spec=测试 gate reject 路径', '--json') -TimeoutSeconds 900
        $json = ConvertFrom-SpecifyJson -Text $res.StdOut -Context 'p0-03 reject run'
        if ($json.status -ne 'paused' -or $json.current_step_id -ne 'question_gate') { throw "expected pause at question_gate, got $($json.status)/$($json.current_step_id)" }
        $rejectRun = $json.run_id
        $res2 = Invoke-Specify -Arguments @('workflow', 'resume', $rejectRun, '--input', 'question_verdict=reject', '--json') -TimeoutSeconds 900
        Save-Evidence -Name 'p0-03\reject-path.txt' -Content ("### run`n" + $res.StdOut + "`n### resume reject (exit " + $res2.ExitCode + ")`n" + $res2.StdOut) | Out-Null
        $json2 = ConvertFrom-SpecifyJson -Text $res2.StdOut -Context 'p0-03 reject resume'
        if ($json2.status -ne 'aborted') { throw "expected aborted, got $($json2.status)" }
        if ($res2.ExitCode -eq 0) { throw 'aborted run returned exit code 0' }
        $statusRes = Invoke-Specify -Arguments @('workflow', 'status', $rejectRun, '--json')
        $statusJson = ConvertFrom-SpecifyJson -Text $statusRes.StdOut -Context 'p0-03 reject status'
        foreach ($step in @('propose_architecture', 'decision_gate', 'report_choice')) {
            if ($statusJson.steps.PSObject.Properties.Name -contains $step) { throw "step $step ran after a rejected gate" }
        }
        "run $rejectRun aborted at question_gate (exit $($res2.ExitCode)); no later step started"
    }
}

# ===========================================================================
# Summary
# ===========================================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Summary' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$passed = @($script:Results | Where-Object { $_.Status -eq 'passed' }).Count
$failed = @($script:Results | Where-Object { $_.Status -eq 'failed' }).Count
$notRun = @($script:Results | Where-Object { $_.Status -eq 'not_run' }).Count
$script:Results | Format-Table -AutoSize Id, Status, Title | Out-String -Width 200 | Write-Host
Write-Host ("passed={0}  failed={1}  not_run={2}" -f $passed, $failed, $notRun)

$summaryPath = Save-Evidence -Name 'summary.json' -Content (ConvertTo-Json -InputObject ([pscustomobject]@{
    generated_at = (Get-Date).ToString('o')
    phase        = $Phase
    specify      = $SpecifyExe
    pi_extra     = $script:PiExtraArgs
    passed       = $passed
    failed       = $failed
    not_run      = $notRun
    checks       = $script:Results
}) -Depth 5)
Write-Host "summary: $summaryPath"

if ($failed -gt 0) { exit 1 }
exit 0
