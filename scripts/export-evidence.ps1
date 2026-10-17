<#
.SYNOPSIS
    Publishes a reviewable, redacted snapshot of the P0 verification evidence.

.DESCRIPTION
    Evidence in a repository must never carry business content or local identity.
    Policy, enforced by construction:

      * SAFE (default, `-Mode summary`): METADATA ONLY — statuses, exit codes,
        timings, byte counts and SHA-256 digests. Prompts, business answers,
        model output, and raw error strings are never written.
      * RAW (`-IncludeModelOutput`): copies transcripts for local incident
        analysis only, and REFUSES to write anywhere inside the git working tree.
      * Raw Pi session transcripts are never copied in any mode.

    Hardening added after the third review round (VERIFICATION-FIX-M2):

      1. every artefact — including MANIFEST.md itself — is written through the
         single choke point `Write-SafeFile`, which applies `Protect-EvidenceText`
         and then `Test-SensitiveLeak`;
      2. `state.error` text is never exported: only a controlled classification,
         a length and a digest;
      3. after writing, the whole target directory is re-scanned and the script
         exits non-zero if anything sensitive is detected (fail closed);
      4. free text that cannot be classified safely is not exported at all.

    This is defence in depth, NOT a guarantee. A regular-expression scrubber
    cannot know every possible business secret; the guarantee comes from not
    exporting unclassified free text in the first place. See
    docs/verification/P0-01-P0-03-integration-report.md §15.

.PARAMETER EvidenceDir
    Local evidence produced by `verify-p0.ps1`. Default: <repo>\.p0-evidence

.PARAMETER TargetRoot
    Export destination. Default: <repo>\docs\verification\evidence\<yyyy-MM-dd>

.PARAMETER RunsDir
    Spec Kit run state directory. Default: <repo>\.specify\workflows\runs

.PARAMETER IncludeModelOutput
    Opt-in raw export (must point outside the repository).

.PARAMETER ForbidLiteral
    Extra literals that must never appear in the export (e.g. a marker injected
    by a test). Repeatable.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\export-evidence.ps1
#>
[CmdletBinding()]
param(
    [string]$EvidenceDir = '',
    [string]$TargetRoot = '',
    [string]$RunsDir = '',
    [switch]$IncludeModelOutput,
    [string[]]$ForbidLiteral = @()
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

$script:Redactions = 0
$script:Withheld = New-Object System.Collections.ArrayList
$script:Written = New-Object System.Collections.ArrayList
$script:GateFailures = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------------------
# Single write choke point
# ---------------------------------------------------------------------------
function Write-SafeFile {
    <#
        The ONLY way this script writes into the target directory.

        1. strip local identity and token shapes (Protect-EvidenceText)
        2. run the leak detector over the result (Test-SensitiveLeak)
        3. fail closed: on a detection the file is NOT written, the finding is
           recorded, and the script exits non-zero at the end
    #>
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [AllowEmptyString()][Parameter(Mandatory)][string]$Content
    )

    $protected = Protect-EvidenceText -Text $Content
    $script:Redactions += $protected.Replacements

    $findings = @(Test-SensitiveLeak -Text $protected.Text -ForbidLiterals $ForbidLiteral)
    if ($findings.Count -gt 0) {
        [void]$script:GateFailures.Add("$RelativePath -> $($findings -join '; ')")
        Write-Warning "leak gate refused to write '$RelativePath': $($findings -join '; ')"
        return $false
    }

    $path = Join-Path $TargetRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllText($path, $protected.Text, (New-Object System.Text.UTF8Encoding $false))
    [void]$script:Written.Add($RelativePath)
    return $true
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
        [void]$script:Withheld.Add([pscustomobject]@{
            Path   = ($RelativePath -replace '\\', '/') + '/'
            Bytes  = [int]$totalBytes
            Sha256 = $aggregate.Sha256
            Reason = "$Reason (directory: $($files.Count) files, aggregate digest of per-file SHA-256)"
        })
        return
    }

    $digest = Get-TextDigest -Path $src
    [void]$script:Withheld.Add([pscustomobject]@{
        Path   = ($RelativePath -replace '\\', '/')
        Bytes  = $digest.Length
        Sha256 = $digest.Sha256
        Reason = $Reason
    })
}

function Get-ErrorClass {
    <#
        Maps a raw engine error string to a controlled vocabulary value. The raw
        string itself is NEVER exported (it can embed paths, prompts or agent
        output); only this class, its length and its digest are.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return 'none' }

    $rules = @(
        @{ Pattern = 'Gate rejected by user';                 Class = 'gate_rejected' },
        @{ Pattern = 'does not match any configured option';  Class = 'invalid_verdict' },
        @{ Pattern = 'Prompt timed out';                      Class = 'prompt_timeout' },
        @{ Pattern = 'timed out';                             Class = 'timeout' },
        @{ Pattern = 'exited with code';                      Class = 'nonzero_exit' },
        @{ Pattern = 'not found or not installed';            Class = 'integration_unavailable' },
        @{ Pattern = 'Interrupted';                           Class = 'interrupted' },
        @{ Pattern = 'must be';                               Class = 'contract_violation' }
    )
    foreach ($rule in $rules) {
        if ($Message -match $rule.Pattern) { return $rule.Class }
    }
    return 'other'
}

# ---------------------------------------------------------------------------
# 1) Source selection
# ---------------------------------------------------------------------------
if ($IncludeModelOutput) {
    Get-ChildItem $EvidenceDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($EvidenceDir.TrimEnd('\').Length).TrimStart('\')
        if ($rel -like 'pi-sessions*') { Add-Withheld -RelativePath $rel -Reason 'raw Pi session transcript (never exported)'; return }
        $text = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        [void](Write-SafeFile -RelativePath $rel -Content $text)
    }
    Write-Warning 'RAW export: model output and business text are included. Local debugging only; never copy this into the repository.'
} else {
    # Files that are safe by construction: no prompts, no model text, no free-form
    # business content. They still pass through the choke point.
    $safeSet = @(
        @{ Source = 'p0-01\environment.txt';        Dest = 'p0-01\environment.txt' },
        @{ Source = 'p0-02\integration-status.txt'; Dest = 'p0-02\integration-status.txt' },
        @{ Source = 'p0-03\workflow-info.txt';      Dest = 'p0-03\workflow-info.txt' }
    )
    foreach ($item in $safeSet) {
        $src = Join-Path $EvidenceDir $item.Source
        if (-not (Test-Path $src)) { Write-Warning "missing: $($item.Source)"; continue }
        $text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
        [void](Write-SafeFile -RelativePath $item.Dest -Content $text)
    }

    # 1b) Verification results: identifiers + status only (no free-text details).
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
        if ($summary.verdict) { [void]$lines.Add('') ; [void]$lines.Add("Verdict: $($summary.verdict)") }
        [void]$lines.Add('')
        [void]$lines.Add('| id | status | title |')
        [void]$lines.Add('| --- | --- | --- |')
        foreach ($check in $summary.checks) {
            $title = $check.Title -replace '\|', '\|'
            [void]$lines.Add("| $($check.Id) | $($check.Status) | $title |")
        }
        [void]$lines.Add('')
        [void]$lines.Add('Free-text check details are deliberately not exported (they can quote agent output).')
        [void]$lines.Add('Reproduce with `powershell -ExecutionPolicy Bypass -File .\scripts\verify-p0.ps1`;')
        [void]$lines.Add('the full detail stays in the local `.p0-evidence\summary.json`.')
        [void](Write-SafeFile -RelativePath 'verification-summary.md' -Content ($lines -join "`n"))

        $redactedJson = $summary.checks | ForEach-Object { [pscustomobject]@{ id = $_.Id; status = $_.Status; title = $_.Title } }
        [void](Write-SafeFile -RelativePath 'summary.redacted.json' -Content (ConvertTo-Json -InputObject ([pscustomobject]@{
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
# 2) Run state: controlled fields only
# ---------------------------------------------------------------------------
if (Test-Path $RunsDir) {
    $runLines = New-Object System.Collections.ArrayList
    [void]$runLines.Add('# Spec Kit run state snapshot (metadata only)')
    [void]$runLines.Add('')
    [void]$runLines.Add('Prompt text, business answers, captured model output and raw engine error strings are')
    [void]$runLines.Add('deliberately omitted. `stdout` / `stderr` are represented by byte count + SHA-256, and')
    [void]$runLines.Add('`error` is represented by a controlled classification + digest, so a reviewer can prove')
    [void]$runLines.Add('a failure occurred and was not edited, without publishing its content.')
    [void]$runLines.Add('')

    $runIds = @()
    foreach ($run in Get-ChildItem $RunsDir -Directory | Sort-Object Name) {
        $statePath = Join-Path $run.FullName 'state.json'
        if (-not (Test-Path $statePath)) { continue }
        $runIds += $run.Name
        $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json

        [void]$runLines.Add("## run ``$($state.run_id)`` — ``$($state.workflow_id)``")
        [void]$runLines.Add('')
        [void]$runLines.Add('| field | value |')
        [void]$runLines.Add('| --- | --- |')
        [void]$runLines.Add("| status | ``$($state.status)`` |")
        [void]$runLines.Add("| current_step | ``$($state.current_step_id)`` (index $($state.current_step_index)) |")
        [void]$runLines.Add("| created_at | $($state.created_at) |")
        [void]$runLines.Add("| updated_at | $($state.updated_at) |")

        $rawError = ''
        if ($state.PSObject.Properties.Name -contains 'error' -and $state.error) { $rawError = [string]$state.error }
        $errorClass = Get-ErrorClass -Message $rawError
        if ($errorClass -eq 'none') {
            [void]$runLines.Add('| error | none |')
        } else {
            $errDigest = Get-TextDigest -Text $rawError
            [void]$runLines.Add("| error | ``$errorClass`` (chars: $($errDigest.Length), sha256: $($errDigest.Sha256.Substring(0, 16))…) |")
        }

        if ($state.PSObject.Properties.Name -contains 'inputs' -and $state.inputs) {
            $inputNames = @($state.inputs.PSObject.Properties.Name | Sort-Object)
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
            $errDigestCell = ''
            if ($step.PSObject.Properties.Name -contains 'output' -and $step.output) {
                if ($step.output.PSObject.Properties.Name -contains 'exit_code') { $exit = [string]$step.output.exit_code }
                if ($step.output.PSObject.Properties.Name -contains 'dispatched') { $dispatched = [string]$step.output.dispatched }
                if ($step.output.PSObject.Properties.Name -contains 'stdout') {
                    $d = Get-TextDigest -Text ([string]$step.output.stdout)
                    if ($d.Length -gt 0) { $outDigest = "$($d.Length)B sha256:$($d.Sha256.Substring(0, 12))…" }
                }
                if ($step.output.PSObject.Properties.Name -contains 'stderr') {
                    $d = Get-TextDigest -Text ([string]$step.output.stderr)
                    if ($d.Length -gt 0) { $errDigestCell = "$($d.Length)B sha256:$($d.Sha256.Substring(0, 12))…" }
                }
            }
            [void]$runLines.Add("| $($prop.Name) | $($step.type) | $($step.status) | $exit | $dispatched | $outDigest | $errDigestCell |")
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
        [void](Write-SafeFile -RelativePath 'run-state-snapshot.md' -Content ($runLines -join "`n"))
    }
}

# ---------------------------------------------------------------------------
# 3) Manifest (also written through the choke point)
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
[void]$manifest.Add('- Safe mode never writes prompts, business answers, model output, or raw engine')
[void]$manifest.Add('  error strings — only statuses, exit codes, timings, controlled error classes,')
[void]$manifest.Add('  and byte count + SHA-256 of captured streams.')
[void]$manifest.Add('- Every artefact (this manifest included) passes through one choke point that')
[void]$manifest.Add('  strips local identity/token shapes and then re-runs a leak detector; a')
[void]$manifest.Add('  detection means the file is not written and the export exits non-zero.')
[void]$manifest.Add('- Unclassified free text is not exported at all. Pattern scrubbing is defence in')
[void]$manifest.Add('  depth, not a guarantee.')
[void]$manifest.Add('- Raw Pi session transcripts are never exported in any mode.')
[void]$manifest.Add('- Raw model output is refused inside the git working tree (`-IncludeModelOutput` guard).')
[void]$manifest.Add('')
[void]$manifest.Add("Redactions applied: **$($script:Redactions)** (path/token patterns)")
if ($ForbidLiteral.Count -gt 0) {
    [void]$manifest.Add('')
    [void]$manifest.Add("Forbidden literals checked: **$($ForbidLiteral.Count)**")
}
[void]$manifest.Add('')
[void]$manifest.Add('## Exported files')
[void]$manifest.Add('')
if ($script:Written.Count -eq 0) {
    [void]$manifest.Add('_none_')
} else {
    [void]$manifest.Add('| file | sha256 | bytes |')
    [void]$manifest.Add('| --- | --- | --- |')
    foreach ($rel in $script:Written) {
        $dst = Join-Path $TargetRoot $rel
        $digest = Get-TextDigest -Path $dst
        [void]$manifest.Add("| ``$($rel -replace '\\', '/')`` | ``$($digest.Sha256)`` | $($digest.Length) |")
    }
    [void]$manifest.Add('')
    [void]$manifest.Add('(A manifest cannot list or hash itself; it is written last and also passes the choke point.)')
}
[void]$manifest.Add('')
[void]$manifest.Add('## Withheld local evidence')
[void]$manifest.Add('')
[void]$manifest.Add('Present locally, intentionally not exported. Reproduce with `scripts\verify-p0.ps1`.')
[void]$manifest.Add('')
if ($script:Withheld.Count -eq 0) {
    [void]$manifest.Add('_none_')
} else {
    [void]$manifest.Add('| local path | bytes | sha256 | reason |')
    [void]$manifest.Add('| --- | --- | --- | --- |')
    foreach ($item in $script:Withheld) {
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

[void](Write-SafeFile -RelativePath 'MANIFEST.md' -Content ($manifest -join "`n"))

# ---------------------------------------------------------------------------
# 4) Post-write self-scan of the WHOLE target directory (fail closed)
# ---------------------------------------------------------------------------
$scanFindings = New-Object System.Collections.ArrayList
foreach ($file in Get-ChildItem $TargetRoot -Recurse -File) {
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    $findings = @(Test-SensitiveLeak -Text $text -ForbidLiterals $ForbidLiteral)
    foreach ($finding in $findings) {
        $rel = $file.FullName.Substring($TargetRoot.TrimEnd('\').Length).TrimStart('\')
        [void]$scanFindings.Add("$rel -> $finding")
    }
}

Write-Host "Evidence snapshot written to: $TargetRoot"
Write-Host "  mode: $(if ($IncludeModelOutput) { 'RAW (outside repo)' } else { 'safe summary' })"
Write-Host "  exported: $($script:Written.Count) file(s), redactions: $($script:Redactions), withheld: $(@($script:Withheld | Where-Object { $_.Sha256 }).Count)"
$script:Written | ForEach-Object { Write-Host "    $_" }

if ($script:GateFailures.Count -gt 0 -or $scanFindings.Count -gt 0) {
    Write-Host ''
    Write-Host 'SELF-CHECK FAILED - export is not safe to publish:' -ForegroundColor Red
    $script:GateFailures | ForEach-Object { Write-Host "  write gate: $_" -ForegroundColor Red }
    $scanFindings | ForEach-Object { Write-Host "  post-write scan: $_" -ForegroundColor Red }
    exit 1
}

Write-Host '  self-check: no local path, token shape or forbidden literal detected' -ForegroundColor Green
exit 0
