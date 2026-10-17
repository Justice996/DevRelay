<#
.SYNOPSIS
    Publishes a reviewable, redacted snapshot of the P0 verification evidence.

.DESCRIPTION
    VERIFICATION-FIX-03 (code review): the first version of this script copied
    raw runner transcripts into the repository, which contained model output and
    business text. Evidence that lands in a public repository must never carry
    business content, so the default behaviour changed:

      * SAFE (default, `-Mode summary`): writes METADATA ONLY — exit codes,
        statuses, step tables, log timelines, and SHA-256 digests + byte counts
        of the captured streams. Model output, prompts and business answers are
        never written, not even truncated.
      * RAW (`-IncludeModelOutput`): copies the raw transcripts for local
        incident analysis only, and REFUSES to write anywhere inside the git
        working tree. Raw Pi session transcripts are never copied in any mode.

    Personal paths and token-shaped strings are stripped from every exported
    file (`Protect-EvidenceText`).

    Withheld material is not hidden: `MANIFEST.md` lists each withheld local file
    with its SHA-256 and byte count, so a reviewer knows exactly what exists and
    can regenerate it with `scripts\verify-p0.ps1`.

.PARAMETER EvidenceDir
    Local evidence produced by `verify-p0.ps1`. Default: <repo>\.p0-evidence

.PARAMETER TargetRoot
    Export destination. Default: <repo>\docs\verification\evidence\<yyyy-MM-dd>

.PARAMETER RunsDir
    Spec Kit run state directory. Default: <repo>\.specify\workflows\runs

.PARAMETER IncludeModelOutput
    Opt-in raw export (must point outside the repository).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\export-evidence.ps1

.EXAMPLE
    # local-only raw copy for debugging; refused if TargetRoot is inside the repo
    powershell -ExecutionPolicy Bypass -File .\scripts\export-evidence.ps1 `
        -IncludeModelOutput -TargetRoot "$env:TEMP\devrelay-evidence-raw"
#>
[CmdletBinding()]
param(
    [string]$EvidenceDir = '',
    [string]$TargetRoot = '',
    [string]$RunsDir = '',
    [switch]$IncludeModelOutput
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\verification-lib.ps1')

if ([string]::IsNullOrWhiteSpace($EvidenceDir)) { $EvidenceDir = Join-Path $RepoRoot '.p0-evidence' }
if ([string]::IsNullOrWhiteSpace($TargetRoot)) { $TargetRoot = Join-Path $RepoRoot ('docs\verification\evidence\' + (Get-Date -Format 'yyyy-MM-dd')) }
if ([string]::IsNullOrWhiteSpace($RunsDir)) { $RunsDir = Join-Path $RepoRoot '.specify\workflows\runs' }

if (-not (Test-Path $EvidenceDir)) { throw "No evidence at $EvidenceDir. Run scripts\verify-p0.ps1 first." }

function Test-PathInside {
    param([string]$Child, [string]$Parent)
    $c = [System.IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $p = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    return ($c -eq $p -or $c.StartsWith($p + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
}

# --- raw-export guard ------------------------------------------------------
$targetIsInRepo = Test-PathInside -Child $TargetRoot -Parent $RepoRoot
if ($IncludeModelOutput -and $targetIsInRepo) {
    throw ("Refusing to export raw model output into the git working tree ($RepoRoot). " +
        'Pass -TargetRoot pointing outside the repository, or drop -IncludeModelOutput for the safe summary export.')
}

New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null

$redactions = 0
$withheld = New-Object System.Collections.ArrayList
$written = New-Object System.Collections.ArrayList

function Write-Redacted {
    param([string]$RelativePath, [string]$Content)
    $path = Join-Path $TargetRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $protected = Protect-EvidenceText -Text $Content
    $script:redactions += $protected.Replacements
    [System.IO.File]::WriteAllText($path, $protected.Text, (New-Object System.Text.UTF8Encoding $false))
    [void]$script:written.Add($RelativePath)
    return $protected.Text
}

function Add-Withheld {
    param([string]$RelativePath, [string]$Reason)
    $src = Join-Path $EvidenceDir $RelativePath
    if (-not (Test-Path $src)) { return }

    if (Test-Path $src -PathType Container) {
        # Directories (e.g. pi-sessions/) are inventoried by an aggregate digest.
        $files = @(Get-ChildItem $src -Recurse -File | Sort-Object FullName)
        if ($files.Count -eq 0) { return }
        $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
        $manifestText = ($files | ForEach-Object {
            $d = Get-TextDigest -Path $_.FullName
            "$($_.Name):$($d.Sha256)"
        }) -join "`n"
        $aggregate = Get-TextDigest -Text $manifestText
        [void]$script:withheld.Add([pscustomobject]@{
            Path   = ($RelativePath -replace '\\', '/') + '/'
            Bytes  = [int]$totalBytes
            Sha256 = $aggregate.Sha256
            Reason = "$Reason (directory: $($files.Count) files, aggregate digest of per-file SHA-256)"
        })
        return
    }

    $digest = Get-TextDigest -Path $src
    [void]$script:withheld.Add([pscustomobject]@{
        Path   = ($RelativePath -replace '\\', '/')
        Bytes  = $digest.Length
        Sha256 = $digest.Sha256
        Reason = $Reason
    })
}

# ---------------------------------------------------------------------------
# 1) Files that are safe by construction (no prompts, no model text)
# ---------------------------------------------------------------------------
$safeSet = @(
    @{ Source = 'p0-01\environment.txt';            Dest = 'p0-01\environment.txt';          Note = 'version inventory + CLI help, no prompts' },
    @{ Source = 'p0-02\integration-status.txt';     Dest = 'p0-02\integration-status.txt';   Note = 'specify integration status' },
    @{ Source = 'p0-03\workflow-info.txt';          Dest = 'p0-03\workflow-info.txt';        Note = 'workflow step graph + exit code' }
)

if ($IncludeModelOutput) {
    # Raw mode: everything except Pi session transcripts.
    Get-ChildItem $EvidenceDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($EvidenceDir.TrimEnd('\').Length).TrimStart('\')
        if ($rel -like 'pi-sessions*') { Add-Withheld -RelativePath $rel -Reason 'raw Pi session transcript (never exported)'; return }
        $text = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        [void](Write-Redacted -RelativePath $rel -Content $text)
    }
    Write-Warning 'RAW export: model output and business text are included. Do not copy this directory into the repository.'
} else {
    foreach ($item in $safeSet) {
        $src = Join-Path $EvidenceDir $item.Source
        if (-not (Test-Path $src)) { Write-Warning "missing: $($item.Source)"; continue }
        $text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
        [void](Write-Redacted -RelativePath $item.Dest -Content $text)
    }

    # 1b) Verification results: identifiers + status only. A check's free-text
    #     detail may quote model output, so it is kept for failures only, with
    #     redaction and a hard length cap.
    $summaryPath = Join-Path $EvidenceDir 'summary.json'
    if (Test-Path $summaryPath) {
        $summary = Get-Content $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('# Verification summary (redacted)')
        [void]$lines.Add('')
        [void]$lines.Add("Generated: $($summary.generated_at)  ")
        [void]$lines.Add("Phase: ``$($summary.phase)``  ")
        [void]$lines.Add("Specify CLI: ``$($summary.specify)``  ")
        [void]$lines.Add("Passed / failed / not_run: **$($summary.passed) / $($summary.failed) / $($summary.not_run)**  ")
        [void]$lines.Add("Exit code: ``$($summary.exit_code)``")
        if ($summary.verdict) { [void]$lines.Add("") ; [void]$lines.Add("Verdict: $($summary.verdict)") }
        [void]$lines.Add('')
        [void]$lines.Add('| id | status | title |')
        [void]$lines.Add('| --- | --- | --- |')
        foreach ($check in $summary.checks) {
            $title = $check.Title -replace '\|', '\|'
            [void]$lines.Add("| $($check.Id) | $($check.Status) | $title |")
        }
        # Deliberately NO free-text check details in the public snapshot: a check's
        # detail is harness-generated today but could start quoting agent output
        # tomorrow. Reproduce locally instead.
        $failedDetails = @($summary.checks | Where-Object { $_.Status -eq 'failed' })
        if ($failedDetails.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('## Failed checks')
            [void]$lines.Add('')
            [void]$lines.Add('Free-text failure details are not exported (they can quote agent output).')
            [void]$lines.Add('Reproduce with `powershell -ExecutionPolicy Bypass -File .\scripts\verify-p0.ps1`;')
            [void]$lines.Add('the full detail stays in the local `.p0-evidence\summary.json`.')
            [void]$lines.Add('')
            foreach ($check in $failedDetails) {
                [void]$lines.Add("- ``$($check.Id)`` — $($check.Title)")
            }
        }
        [void](Write-Redacted -RelativePath 'verification-summary.md' -Content ($lines -join "`n"))

        $redactedJson = $summary.checks | ForEach-Object { [pscustomobject]@{ id = $_.Id; status = $_.Status; title = $_.Title } }
        [void](Write-Redacted -RelativePath 'summary.redacted.json' -Content (ConvertTo-Json -InputObject ([pscustomobject]@{
            generated_at = $summary.generated_at
            phase        = $summary.phase
            passed       = $summary.passed
            failed       = $summary.failed
            not_run      = $summary.not_run
            exit_code    = $summary.exit_code
            verdict      = $summary.verdict
            checks       = @($redactedJson)
        }) -Depth 4))

        Add-Withheld -RelativePath 'summary.json' -Reason 'full check details may quote model output; redacted version exported as summary.redacted.json'
    }

    foreach ($rel in @('full-run-console.txt', 'p0-01\pi-empty-dir-smoke.txt', 'p0-02\probe-run.txt',
                       'p0-02\capture-probe.txt', 'p0-03\phase1-run.txt', 'p0-03\phase2-resume.txt',
                       'p0-03\phase3-resume.txt', 'p0-03\final-status.txt', 'p0-03\reject-path.txt')) {
        Add-Withheld -RelativePath $rel -Reason 'raw runner transcript containing model output / business text'
    }
    if (Test-Path (Join-Path $EvidenceDir 'pi-sessions')) {
        Add-Withheld -RelativePath 'pi-sessions' -Reason 'raw Pi session transcripts (never exported)'
    }
}

# ---------------------------------------------------------------------------
# 2) Run state: metadata only (no prompt text, no model text)
# ---------------------------------------------------------------------------
if (Test-Path $RunsDir) {
    $runLines = New-Object System.Collections.ArrayList
    [void]$runLines.Add('# Spec Kit run state snapshot (metadata only)')
    [void]$runLines.Add('')
    [void]$runLines.Add('Prompt text, business answers and captured model output are deliberately omitted.')
    [void]$runLines.Add('`stdout` / `stderr` are represented by byte count + SHA-256 so a reviewer can prove the')
    [void]$runLines.Add('captured streams existed and were not edited, without publishing their content.')
    [void]$runLines.Add('')

    $runIds = @()
    foreach ($run in Get-ChildItem $RunsDir -Directory | Sort-Object Name) {
        $statePath = Join-Path $run.FullName 'state.json'
        if (-not (Test-Path $statePath)) { continue }
        $runIds += $run.Name
        $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json

        [void]$runLines.Add("## run ``$($state.run_id)`` — ``$($state.workflow_id)``")
        [void]$runLines.Add('')
        [void]$runLines.Add("| field | value |")
        [void]$runLines.Add('| --- | --- |')
        [void]$runLines.Add("| status | ``$($state.status)`` |")
        [void]$runLines.Add("| current_step | ``$($state.current_step_id)`` (index $($state.current_step_index)) |")
        [void]$runLines.Add("| created_at | $($state.created_at) |")
        [void]$runLines.Add("| updated_at | $($state.updated_at) |")
        if ($state.error) {
            $errText = [string]$state.error
            if ($errText.Length -gt 200) { $errText = $errText.Substring(0, 200) + '…' }
            [void]$runLines.Add("| error | ``$($errText -replace '\|', '\|')`` |")
        }
        if ($state.PSObject.Properties.Name -contains 'inputs' -and $state.inputs) {
            $inputNames = @($state.inputs.PSObject.Properties.Name)
            $quotedNames = ($inputNames | ForEach-Object { '`' + $_ + '`' }) -join ', '
            [void]$runLines.Add("| input names | $quotedNames |")
        }
        [void]$runLines.Add('')

        [void]$runLines.Add('| step | type | status | exit_code | dispatched | captured stdout | captured stderr |')
        [void]$runLines.Add('| --- | --- | --- | --- | --- | --- | --- |')
        foreach ($prop in $state.step_results.PSObject.Properties) {
            $step = $prop.Value
            $exit = ''
            $dispatched = ''
            $outDigest = ''
            $errDigest = ''
            if ($step.PSObject.Properties.Name -contains 'output' -and $step.output) {
                if ($step.output.PSObject.Properties.Name -contains 'exit_code') { $exit = $step.output.exit_code }
                if ($step.output.PSObject.Properties.Name -contains 'dispatched') { $dispatched = $step.output.dispatched }
                if ($step.output.PSObject.Properties.Name -contains 'stdout') {
                    $d = Get-TextDigest -Text ([string]$step.output.stdout)
                    if ($d.Length -gt 0) { $outDigest = "$($d.Length)B sha256:$($d.Sha256.Substring(0, 12))…" }
                }
                if ($step.output.PSObject.Properties.Name -contains 'stderr') {
                    $d = Get-TextDigest -Text ([string]$step.output.stderr)
                    if ($d.Length -gt 0) { $errDigest = "$($d.Length)B sha256:$($d.Sha256.Substring(0, 12))…" }
                }
            }
            [void]$runLines.Add("| $($prop.Name) | $($step.type) | $($step.status) | $exit | $dispatched | $outDigest | $errDigest |")
        }

        $logPath = Join-Path $run.FullName 'log.jsonl'
        if (Test-Path $logPath) {
            [void]$runLines.Add('')
            [void]$runLines.Add('```text')
            Get-Content $logPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
                $e = $_ | ConvertFrom-Json
                # Older/newer log events are not guaranteed to carry every field;
                # StrictMode turns a missing property into a hard failure.
                $evt = if ($e.PSObject.Properties.Name -contains 'event') { [string]$e.event } else { '' }
                $stepId = if ($e.PSObject.Properties.Name -contains 'step_id') { [string]$e.step_id } else { '' }
                $st = if ($e.PSObject.Properties.Name -contains 'status') { [string]$e.status } else { '' }
                $ts = if ($e.PSObject.Properties.Name -contains 'timestamp') { [string]$e.timestamp } else { '' }
                [void]$runLines.Add("$ts  $($evt.PadRight(18)) $stepId $st")
            }
            [void]$runLines.Add('```')
        }
        [void]$runLines.Add('')
    }

    if ($runIds.Count -gt 0) {
        [void](Write-Redacted -RelativePath 'run-state-snapshot.md' -Content ($runLines -join "`n"))
    }
}

# ---------------------------------------------------------------------------
# 3) Manifest with redaction + withheld accounting
# ---------------------------------------------------------------------------
$manifest = New-Object System.Collections.ArrayList
[void]$manifest.Add('# Evidence manifest')
[void]$manifest.Add('')
[void]$manifest.Add("Mode: **$(if ($IncludeModelOutput) { 'RAW — local debugging only' } else { 'safe (metadata only)' })**")
[void]$manifest.Add('')
[void]$manifest.Add("Source evidence: ``$EvidenceDir``")
[void]$manifest.Add('')
[void]$manifest.Add('## Policy')
[void]$manifest.Add('')
[void]$manifest.Add('- Safe mode never writes prompts, business answers or model output — only statuses,')
[void]$manifest.Add('  exit codes, timings, and byte count + SHA-256 of captured streams.')
[void]$manifest.Add('- Personal paths and token-shaped strings are stripped (`scripts/lib/verification-lib.ps1`).')
[void]$manifest.Add('- Raw Pi session transcripts are never exported in any mode.')
[void]$manifest.Add('- Raw model output is refused inside the git working tree (`-IncludeModelOutput` guard).')
[void]$manifest.Add('')
[void]$manifest.Add("Redactions applied: **$redactions** (path/token patterns)")
[void]$manifest.Add('')
[void]$manifest.Add('## Exported files')
[void]$manifest.Add('')
if ($written.Count -eq 0) {
    [void]$manifest.Add('_none_')
} else {
    [void]$manifest.Add('| file | sha256 | bytes |')
    [void]$manifest.Add('| --- | --- | --- |')
    foreach ($rel in $written) {
        $dst = Join-Path $TargetRoot $rel
        $digest = Get-TextDigest -Path $dst
        [void]$manifest.Add("| ``$($rel -replace '\\', '/')`` | ``$($digest.Sha256)`` | $($digest.Length) |")
    }
}
[void]$manifest.Add('')
[void]$manifest.Add('## Withheld local evidence')
[void]$manifest.Add('')
[void]$manifest.Add('Present locally, intentionally not exported. Reproduce with `scripts\verify-p0.ps1`.')
[void]$manifest.Add('')
if ($withheld.Count -eq 0) {
    [void]$manifest.Add('_none_')
} else {
    [void]$manifest.Add('| local path | bytes | sha256 | reason |')
    [void]$manifest.Add('| --- | --- | --- | --- |')
    foreach ($item in $withheld) {
        if (-not $item.Sha256) { continue }
        [void]$manifest.Add("| ``$($item.Path)`` | $($item.Bytes) | ``$($item.Sha256)`` | $($item.Reason) |")
    }
}
[void]$manifest.Add('')
[void]$manifest.Add('## Run directories covered')
[void]$manifest.Add('')
if (Test-Path $RunsDir) {
    foreach ($d in Get-ChildItem $RunsDir -Directory | Sort-Object Name) { [void]$manifest.Add("- ``$($d.Name)``") }
} else {
    [void]$manifest.Add('_no runs directory_')
}

[System.IO.File]::WriteAllText((Join-Path $TargetRoot 'MANIFEST.md'), ($manifest -join "`n"), (New-Object System.Text.UTF8Encoding $false))

Write-Host "Evidence snapshot written to: $TargetRoot"
Write-Host "  mode: $(if ($IncludeModelOutput) { 'RAW (outside repo)' } else { 'safe summary' })"
Write-Host "  exported: $($written.Count) file(s), redactions: $redactions, withheld: $(@($withheld | Where-Object { $_.Sha256 }).Count)"
$written | ForEach-Object { Write-Host "    $_" }
