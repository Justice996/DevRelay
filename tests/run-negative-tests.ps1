<#
.SYNOPSIS
    Reverse (negative) tests for the three code-review fixes.

.DESCRIPTION
    A verification assertion that cannot fail is not an assertion. These tests
    feed deliberately wrong input to the exact same code paths the P0 harness
    uses and require each one to be rejected.

    VERIFICATION-FIX-01  strict `workflow info` assertions (P0-03-01)
      R01  valid output                            -> no problems reported
      R02  non-zero exit code                      -> rejected
      R03  a step missing (declared 5, parsed 4)   -> rejected
      R04  steps reordered                         -> rejected
      R05  step type drift (gate -> prompt)        -> rejected
      R06  unparsable output                       -> rejected
      R07  wrong workflow id                       -> rejected
      R08  a check whose assertions can never fail is caught by R02..R07

    VERIFICATION-FIX-02  exit policy: a required check that never ran must not
                         produce exit code 0
      R09  all passed                              -> exit 0
      R10  one failed                              -> exit 1
      R11  one not_run                             -> exit 1   (regression)
      R12  empty result set                        -> exit 1
      R13  unknown status typo ('passd')           -> exit 1

    VERIFICATION-FIX-03  evidence export safety
      R14  safe mode leaks no prompt / model text  -> rejected if any leaks
      R15  safe mode still records provenance      -> digests + withheld list present
      R16  raw mode refused inside the repository  -> must throw
      R17  raw mode outside the repo works         -> marker present, Pi sessions still absent
      R18  personal paths / token shapes redacted  -> replaced in output

    VERIFICATION-FIX-M1  worktree integrity must be content-based
      R19  dirty file edited AGAIN, `git status` string unchanged -> detected
           (this is the exact gap of a porcelain-only comparison)
      R20  no change -> no false alarm
      R21  new untracked file -> detected
      R22  deleted tracked file -> detected

    VERIFICATION-FIX-M2  evidence export: manifest, raw errors, whole-tree scan
      R23  whole export dir free of business secret / personal path / exception
      R24  MANIFEST carries no raw user-profile path
      R25  raw `state.error` text never exported (class + digest only)
      R26  export fails closed when a forbidden literal would be written
      R27  the leak detector itself bites (path / token / literal)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\run-negative-tests.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRootOverride = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = if ($RepoRootOverride) { $RepoRootOverride } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $RepoRoot 'scripts\lib\verification-lib.ps1')

$script:Results = New-Object System.Collections.ArrayList

function Add-Result {
    param([string]$Id, [string]$Title, [string]$Status, [string]$Detail = '')
    [void]$script:Results.Add([pscustomobject]@{ Id = $Id; Title = $Title; Status = $Status; Detail = $Detail })
    $color = @{ passed = 'Green'; failed = 'Red' }[$Status]
    Write-Host ("  [{0,-6}] {1} :: {2}" -f $Status.ToUpperInvariant(), $Id, $Title) -ForegroundColor $color
    if ($Detail) { Write-Host ("           {0}" -f $Detail) -ForegroundColor DarkGray }
}

function Run-Test {
    param([string]$Id, [string]$Title, [scriptblock]$Body)
    try {
        $detail = & $Body
        Add-Result -Id $Id -Title $Title -Status 'passed' -Detail ([string]$detail)
    } catch {
        Add-Result -Id $Id -Title $Title -Status 'failed' -Detail $_.Exception.Message
    }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' DevRelay review-fix reverse tests' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host " repo: $RepoRoot"
Write-Host ''

# ---------------------------------------------------------------------------
# Fixtures: the real `specify workflow info` output shape
# ---------------------------------------------------------------------------
$validInfo = @'
DevRelay Business Collaboration Smoke Test (devrelay-smoke)
  Version:     0.1.0
  Author:      DevRelay
  Description: Verify two human gates with Pi plus a DeepSeek model

  Inputs:
    spec (string) — required

  Steps (5):
    → identify_business_gap [prompt]
    → question_gate [gate]
    → propose_architecture [prompt]
    → decision_gate [gate]
    → report_choice [prompt]
'@

$expectedIds = @('identify_business_gap', 'question_gate', 'propose_architecture', 'decision_gate', 'report_choice')
$expectedTypes = @('prompt', 'gate', 'prompt', 'gate', 'prompt')

function Test-Info {
    param([string]$StdOut, [int]$ExitCode = 0, [string]$WorkflowId = 'devrelay-smoke')
    return Test-WorkflowInfoStrict -ExitCode $ExitCode -StdOut $StdOut -StdErr '' `
        -ExpectedWorkflowId $WorkflowId -ExpectedStepIds $expectedIds -ExpectedStepTypes $expectedTypes
}

# ===========================================================================
# VERIFICATION-FIX-01
# ===========================================================================
Write-Host '--- VERIFICATION-FIX-01: strict workflow info assertions -------------' -ForegroundColor Cyan

Run-Test 'R01' 'Valid workflow info output is accepted (guard against a check that always fails)' {
    $problems = @(Test-Info -StdOut $validInfo)
    if ($problems.Count -ne 0) { throw "valid input was rejected: $($problems -join '; ')" }
    'no problems reported'
}

Run-Test 'R02' 'Non-zero `workflow info` exit code is rejected' {
    $problems = @(Test-Info -StdOut $validInfo -ExitCode 1)
    if ($problems.Count -eq 0) { throw 'exit code 1 was accepted' }
    if (-not ($problems -join '; ') -match 'exited with code 1') { throw "wrong complaint: $($problems -join '; ')" }
    $problems -join '; '
}

Run-Test 'R03' 'A missing step (declared 5, parsed 4) is rejected' {
    $broken = ($validInfo -split "`r?`n" | Where-Object { $_ -notmatch 'report_choice' }) -join "`n"
    $problems = @(Test-Info -StdOut $broken)
    if ($problems.Count -eq 0) { throw 'a missing step was accepted' }
    $problems -join '; '
}

Run-Test 'R04' 'Reordered gate/prompt steps are rejected' {
    $reordered = @'
DevRelay Business Collaboration Smoke Test (devrelay-smoke)
  Steps (5):
    → identify_business_gap [prompt]
    → question_gate [gate]
    → decision_gate [gate]
    → propose_architecture [prompt]
    → report_choice [prompt]
'@
    $problems = @(Test-Info -StdOut $reordered)
    if ($problems.Count -eq 0) { throw 'reordered steps were accepted' }
    $problems -join '; '
}

Run-Test 'R05' 'A gate silently downgraded to a prompt step is rejected' {
    $drift = $validInfo -replace '→ question_gate \[gate\]', '→ question_gate [prompt]'
    $problems = @(Test-Info -StdOut $drift)
    if ($problems.Count -eq 0) { throw 'step type drift was accepted' }
    if (-not ($problems -join '; ') -match "type is 'prompt', expected 'gate'") { throw "wrong complaint: $($problems -join '; ')" }
    $problems -join '; '
}

Run-Test 'R06' 'Unparsable output is rejected (parser drift fails loudly)' {
    $problems = @(Test-Info -StdOut 'Traceback (most recent call last): boom')
    if ($problems.Count -eq 0) { throw 'garbage output was accepted' }
    $problems -join '; '
}

Run-Test 'R07' 'A different workflow id is rejected' {
    $problems = @(Test-Info -StdOut $validInfo -WorkflowId 'some-other-workflow')
    if ($problems.Count -eq 0) { throw 'wrong workflow id was accepted' }
    $problems -join '; '
}

# ===========================================================================
# VERIFICATION-FIX-02
# ===========================================================================
Write-Host ''
Write-Host '--- VERIFICATION-FIX-02: exit policy (not_run must not pass) --------' -ForegroundColor Cyan

function New-Check {
    param([string]$Id, [string]$Status)
    [pscustomobject]@{ Id = $Id; Status = $Status }
}

Run-Test 'R09' 'All checks passed -> exit 0' {
    $code = Get-VerificationExitCode -Results @((New-Check 'A' 'passed'), (New-Check 'B' 'passed'))
    if ($code -ne 0) { throw "exit code $code, expected 0" }
    'exit 0'
}

Run-Test 'R10' 'One failed check -> exit 1' {
    $results = @((New-Check 'A' 'passed'), (New-Check 'B' 'failed'))
    $code = Get-VerificationExitCode -Results $results
    if ($code -ne 1) { throw "exit code $code, expected 1" }
    Get-VerificationExitReason -Results $results
}

Run-Test 'R11' 'One not_run check -> exit 1 (a skipped required check is not a pass)' {
    $results = @((New-Check 'A' 'passed'), (New-Check 'B' 'not_run'))
    $code = Get-VerificationExitCode -Results $results
    if ($code -ne 1) { throw "exit code $code, expected 1 (REGRESSION: not_run was treated as success)" }
    Get-VerificationExitReason -Results $results
}

Run-Test 'R12' 'No checks at all -> exit 1 (nothing was proven)' {
    $code = Get-VerificationExitCode -Results @()
    if ($code -ne 1) { throw "exit code $code, expected 1" }
    Get-VerificationExitReason -Results @()
}

Run-Test 'R13' 'Unknown status typo -> exit 1' {
    $results = @((New-Check 'A' 'passd'))
    $code = Get-VerificationExitCode -Results $results
    if ($code -ne 1) { throw "exit code $code, expected 1" }
    Get-VerificationExitReason -Results $results
}

# ===========================================================================
# VERIFICATION-FIX-M1: content-based worktree integrity
# ===========================================================================
Write-Host ''
Write-Host '--- VERIFICATION-FIX-M1: content-based worktree integrity -----------' -ForegroundColor Cyan

$m1Repo = Join-Path $env:TEMP ("devrelay-m1-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Force -Path $m1Repo | Out-Null
    & git -C $m1Repo init -q -b main
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    [System.IO.File]::WriteAllText((Join-Path $m1Repo 'tracked.txt'), "v1`n")
    [System.IO.File]::WriteAllText((Join-Path $m1Repo 'other.txt'), "v1`n")
    & git -C $m1Repo add -A
    & git -C $m1Repo -c user.email=devrelay@example.invalid -c user.name=devrelay commit -q -m init
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }

    # The developer already has uncommitted work before the verification run.
    [System.IO.File]::WriteAllText((Join-Path $m1Repo 'tracked.txt'), "v2-already-dirty`n")

    Run-Test 'R19' 'A second edit to an already-dirty file is detected even though `git status` is unchanged' {
        $baseline = Get-WorktreeSnapshot -RepoRoot $m1Repo
        $statusBefore = (@($baseline.PorcelainEntries) -join '|')

        # The "verification run" edits the same file again.
        [System.IO.File]::WriteAllText((Join-Path $m1Repo 'tracked.txt'), "v3-changed-during-run`n")
        $after = Get-WorktreeSnapshot -RepoRoot $m1Repo
        $statusAfter = (@($after.PorcelainEntries) -join '|')

        if ($statusBefore -ne $statusAfter) {
            throw "porcelain strings differ ('$statusBefore' vs '$statusAfter') - the scenario does not reproduce the M1 gap"
        }
        $problems = @(Compare-WorktreeSnapshot -Baseline $baseline -Current $after)
        if ($problems.Count -eq 0) { throw 'content-only change went undetected (M1 regression: status-only comparison)' }
        if (-not (($problems -join ' ') -match 'tracked\.txt')) { throw "wrong complaint: $($problems -join '; ')" }
        "porcelain identical ('$statusAfter') yet content drift detected: $($problems -join '; ')"
    }

    Run-Test 'R20' 'An unchanged tree produces no problems (no false alarm)' {
        [System.IO.File]::WriteAllText((Join-Path $m1Repo 'tracked.txt'), "v2-already-dirty`n")
        $baseline = Get-WorktreeSnapshot -RepoRoot $m1Repo
        $after = Get-WorktreeSnapshot -RepoRoot $m1Repo
        $problems = @(Compare-WorktreeSnapshot -Baseline $baseline -Current $after)
        if ($problems.Count -ne 0) { throw "false alarm on an unchanged tree: $($problems -join '; ')" }
        "$($baseline.FileCount) tracked files hashed, no drift reported"
    }

    Run-Test 'R21' 'A new untracked file is detected' {
        $baseline = Get-WorktreeSnapshot -RepoRoot $m1Repo
        [System.IO.File]::WriteAllText((Join-Path $m1Repo 'appeared.txt'), "new`n")
        $after = Get-WorktreeSnapshot -RepoRoot $m1Repo
        $problems = @(Compare-WorktreeSnapshot -Baseline $baseline -Current $after)
        Remove-Item (Join-Path $m1Repo 'appeared.txt') -Force
        if ($problems.Count -eq 0) { throw 'a new untracked file went undetected' }
        $problems -join '; '
    }

    Run-Test 'R22' 'A deleted tracked file is detected' {
        $baseline = Get-WorktreeSnapshot -RepoRoot $m1Repo
        Remove-Item (Join-Path $m1Repo 'other.txt') -Force
        $after = Get-WorktreeSnapshot -RepoRoot $m1Repo
        $problems = @(Compare-WorktreeSnapshot -Baseline $baseline -Current $after)
        if ($problems.Count -eq 0) { throw 'a deleted tracked file went undetected' }
        if (-not (($problems -join ' ') -match 'other\.txt')) { throw "wrong complaint: $($problems -join '; ')" }
        $problems -join '; '
    }
}
finally {
    Remove-Item $m1Repo -Recurse -Force -ErrorAction SilentlyContinue
}

# ===========================================================================
# VERIFICATION-FIX-03
# ===========================================================================
Write-Host ''
Write-Host '--- VERIFICATION-FIX-03: evidence export safety ---------------------' -ForegroundColor Cyan

$marker = 'PLANTED_BUSINESS_TEXT_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fixture = Join-Path $env:TEMP ("devrelay-neg-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$evDir = Join-Path $fixture 'evidence'
$runsDir = Join-Path $fixture 'runs'
$safeOut = Join-Path $fixture 'out-safe'
$rawOut = Join-Path $fixture 'out-raw'
$repoInside = Join-Path $RepoRoot 'tmp-raw-export-should-fail'

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $evDir 'p0-03') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $evDir 'p0-01') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $evDir 'pi-sessions') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $runsDir 'run1') | Out-Null

    # raw transcript + captured model text carrying the business marker
    [System.IO.File]::WriteAllText((Join-Path $evDir 'p0-03\phase1-run.txt'), "model said: $marker", (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Join-Path $evDir 'pi-sessions\s.jsonl'), "{`"text`":`"$marker`"}", (New-Object System.Text.UTF8Encoding $false))
    # A synthetic, token-SHAPED string used only to prove redaction. It is built
    # at runtime (not written as a literal) so secret scanners do not flag the
    # test file itself.
    $fakeToken = 'gh' + 'p_' + ('A' * 36)

    # a "safe" file that still contains a personal path and a token shape
    [System.IO.File]::WriteAllText((Join-Path $evDir 'p0-01\environment.txt'),
        "home=C:\Users\someone\work`ntoken=$fakeToken`n", (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Join-Path $evDir 'summary.json'), (ConvertTo-Json -InputObject ([pscustomobject]@{
        generated_at = '2026-10-17T00:00:00+00:00'
        phase        = 'all'
        specify      = 'specify.exe'
        pi_extra     = '--tools read'
        passed       = 1
        failed       = 1
        not_run      = 0
        exit_code    = 1
        verdict      = '1 failed'
        checks       = @(
            [pscustomobject]@{ Id = 'X-01'; Status = 'passed'; Title = 'ok'; Detail = 'leaked detail: ' + $marker },
            [pscustomobject]@{ Id = 'X-02'; Status = 'failed'; Title = 'bad'; Detail = 'leaked detail: ' + $marker }
        )
    }) -Depth 5), (New-Object System.Text.UTF8Encoding $false))

    # run state: prompt text and captured stdout carry the marker
    [System.IO.File]::WriteAllText((Join-Path $runsDir 'run1\state.json'), (ConvertTo-Json -InputObject ([pscustomobject]@{
        run_id             = 'run1'
        workflow_id        = 'devrelay-smoke'
        status             = 'completed'
        current_step_id    = 'report_choice'
        current_step_index = 4
        created_at         = '2026-10-17T00:00:00+00:00'
        updated_at         = '2026-10-17T00:01:00+00:00'
        error              = $null
        inputs             = [pscustomobject]@{ spec = $marker; product_answer = $marker }
        step_results       = [pscustomobject]@{
            report_choice = [pscustomobject]@{
                type   = 'prompt'
                status = 'completed'
                output = [pscustomobject]@{ prompt = $marker; stdout = $marker; stderr = ''; exit_code = 0; dispatched = $true }
            }
        }
    }) -Depth 8), (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Join-Path $runsDir 'run1\log.jsonl'),
        ('{"timestamp":"2026-10-17T00:00:00+00:00","event":"step_started","step_id":"report_choice","status":""}' + "`n"),
        (New-Object System.Text.UTF8Encoding $false))

    # A second run that failed, whose raw error string embeds a personal path and
    # an exception frame. NONE of that text may appear in the export; only the
    # classification, length and digest.
    New-Item -ItemType Directory -Force -Path (Join-Path $runsDir 'run2') | Out-Null
    $rawErrorText = "Gate rejected by user at step 'question_gate' -- Exception calling `"Run`" at C:\Users\someone\scripts\x.ps1:12: $marker"
    [System.IO.File]::WriteAllText((Join-Path $runsDir 'run2\state.json'), (ConvertTo-Json -InputObject ([pscustomobject]@{
        run_id             = 'run2'
        workflow_id        = 'devrelay-smoke'
        status             = 'aborted'
        current_step_id    = 'question_gate'
        current_step_index = 1
        created_at         = '2026-10-17T00:02:00+00:00'
        updated_at         = '2026-10-17T00:03:00+00:00'
        error              = $rawErrorText
        inputs             = [pscustomobject]@{ spec = $marker }
        step_results       = [pscustomobject]@{
            question_gate = [pscustomobject]@{
                type   = 'gate'
                status = 'failed'
                output = [pscustomobject]@{ message = $marker; choice = 'reject'; exit_code = $null; stdout = ''; stderr = $marker }
            }
        }
    }) -Depth 8), (New-Object System.Text.UTF8Encoding $false))

    $exportScript = Join-Path $RepoRoot 'scripts\export-evidence.ps1'

    Run-Test 'R14' 'Safe export contains no prompt / model / business text' {
        & powershell -ExecutionPolicy Bypass -NoProfile -File $exportScript `
            -EvidenceDir $evDir -RunsDir $runsDir -TargetRoot $safeOut | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "export exited $LASTEXITCODE" }
        $leaks = @(Get-ChildItem $safeOut -Recurse -File | Where-Object {
            (Get-Content $_.FullName -Raw -Encoding UTF8) -like "*$marker*"
        } | ForEach-Object { $_.Name })
        if ($leaks.Count -gt 0) { throw "business marker leaked into: $($leaks -join ', ')" }
        $files = @(Get-ChildItem $safeOut -Recurse -File | ForEach-Object { $_.Name }) -join ', '
        "no leak across: $files"
    }

    Run-Test 'R15' 'Safe export still records provenance (digests + withheld inventory)' {
        $manifest = Get-Content (Join-Path $safeOut 'MANIFEST.md') -Raw -Encoding UTF8
        if ($manifest -notmatch 'Withheld local evidence') { throw 'MANIFEST has no withheld section' }
        if ($manifest -notmatch 'phase1-run\.txt') { throw 'withheld inventory does not list the raw transcript' }
        if ($manifest -notmatch '[0-9a-f]{64}') { throw 'withheld inventory has no sha256 digests' }
        if ($manifest -notmatch 'pi-sessions') { throw 'withheld inventory does not list the pi-sessions directory' }
        $runState = Get-Content (Join-Path $safeOut 'run-state-snapshot.md') -Raw -Encoding UTF8
        if ($runState -notmatch 'sha256:') { throw 'run-state snapshot has no captured-stream digests' }
        if ($runState -notmatch '\| report_choice \| prompt \| completed \| 0 \| True \|') { throw 'run-state snapshot lost the step metadata table' }
        'withheld inventory + digests present'
    }

    Run-Test 'R16' 'Raw export is refused inside the git working tree' {
        $threw = $false
        try {
            & powershell -ExecutionPolicy Bypass -NoProfile -File $exportScript `
                -EvidenceDir $evDir -RunsDir $runsDir -TargetRoot $repoInside -IncludeModelOutput 2>&1 | Out-Null
        } catch {
            $threw = $true
        }
        if (Test-Path $repoInside) {
            Remove-Item $repoInside -Recurse -Force -ErrorAction SilentlyContinue
            throw 'raw export wrote into the repository instead of refusing'
        }
        if ($LASTEXITCODE -eq 0) { throw 'raw export into the repo exited 0' }
        'refused (non-zero exit, nothing written)'
    }

    Run-Test 'R17' 'Raw export outside the repo works but still drops Pi sessions' {
        & powershell -ExecutionPolicy Bypass -NoProfile -File $exportScript `
            -EvidenceDir $evDir -RunsDir $runsDir -TargetRoot $rawOut -IncludeModelOutput | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "raw export exited $LASTEXITCODE" }
        $raw = Get-Content (Join-Path $rawOut 'p0-03\phase1-run.txt') -Raw -Encoding UTF8
        if ($raw -notlike "*$marker*") { throw 'raw mode did not reproduce the transcript' }
        $sessionFiles = @(Get-ChildItem $rawOut -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
        if ($sessionFiles.Count -gt 0) { throw "raw mode copied Pi session files: $($sessionFiles.Name -join ', ')" }
        'raw transcript exported to an out-of-repo path; pi-sessions excluded'
    }

    Run-Test 'R18' 'Personal paths and token-shaped strings are redacted' {
        $envText = Get-Content (Join-Path $safeOut 'p0-01\environment.txt') -Raw -Encoding UTF8
        if ($envText -match 'C:\\Users\\someone') { throw 'personal path not redacted' }
        if ($envText -match 'ghp_[A-Za-z0-9]{16,}') { throw 'token shape not redacted' }
        if ($envText -notmatch '%USERPROFILE%') { throw 'path placeholder missing' }
        'path -> %USERPROFILE%, token -> <redacted-token>'
    }

    Run-Test 'R23' 'Whole export directory is free of business secret, personal path and exception text' {
        $leaks = New-Object System.Collections.ArrayList
        foreach ($file in Get-ChildItem $safeOut -Recurse -File) {
            $text = Get-Content $file.FullName -Raw -Encoding UTF8
            $rel = $file.FullName.Substring($safeOut.TrimEnd('\').Length).TrimStart('\')
            if ($text -like "*$marker*") { [void]$leaks.Add("$rel : business marker") }
            if ($text -match 'C:\\Users\\') { [void]$leaks.Add("$rel : personal path") }
            if ($text -match 'x\.ps1') { [void]$leaks.Add("$rel : exception frame") }
        }
        if ($leaks.Count -gt 0) { throw "leaks found: $($leaks -join '; ')" }
        $scanned = @(Get-ChildItem $safeOut -Recurse -File).Count
        "$scanned files scanned, 0 leaks"
    }

    Run-Test 'R24' 'MANIFEST carries no raw user-profile path' {
        $manifestText = Get-Content (Join-Path $safeOut 'MANIFEST.md') -Raw -Encoding UTF8
        if ($manifestText -match 'C:\\Users\\') { throw 'MANIFEST still contains an absolute user path' }
        if ($manifestText -notmatch '%USERPROFILE%') { throw 'MANIFEST lost the sanitised source path (expected %USERPROFILE%)' }
        'manifest source path sanitised to %USERPROFILE%'
    }

    Run-Test 'R25' 'Raw `state.error` text is never exported (classification + digest only)' {
        $runState = Get-Content (Join-Path $safeOut 'run-state-snapshot.md') -Raw -Encoding UTF8
        if ($runState -match 'Gate rejected by user at step') { throw 'raw error message exported' }
        if ($runState -match 'x\.ps1') { throw 'exception frame from the error exported' }
        if ($runState -notmatch 'gate_rejected') { throw 'error classification missing' }
        # Single-quoted PowerShell strings do not treat ` as an escape, so the
        # backticks below are literal markdown backticks.
        if ($runState -notmatch 'error \| `gate_rejected` \(chars: \d+, sha256: [0-9a-f]{16}') { throw 'error row is not class + length + digest' }
        if ($runState -notmatch '\| error \| none \|') { throw 'a run without an error should render as none' }
        'aborted run shows gate_rejected + digest; completed run shows none'
    }

    Run-Test 'R26' 'Export fails closed when a forbidden literal would be written' {
        # Plant the marker in a file that the safe path normally exports, then ask
        # the exporter to forbid it. The file must not be written and the export
        # must exit non-zero.
        New-Item -ItemType Directory -Force -Path (Join-Path $evDir 'p0-02') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $evDir 'p0-02\integration-status.txt'),
            "status line $marker`n", (New-Object System.Text.UTF8Encoding $false))
        $forbidOut = Join-Path $fixture 'out-forbid'
        & powershell -ExecutionPolicy Bypass -NoProfile -File $exportScript `
            -EvidenceDir $evDir -RunsDir $runsDir -TargetRoot $forbidOut -ForbidLiteral $marker 2>&1 | Out-Null
        $code = $LASTEXITCODE
        if ($code -eq 0) { throw 'export exited 0 although a forbidden literal was present' }
        if (Test-Path (Join-Path $forbidOut 'p0-02\integration-status.txt')) { throw 'the leaking file was written anyway' }
        "exit $code, leaking file not written"
    }

    Run-Test 'R27' 'The leak detector itself bites (path / token / forbidden literal)' {
        $fakeToken2 = 'gh' + 'p_' + ('B' * 36)
        $cases = @(
            @{ Text = "see $env:USERPROFILE\Desktop"; Why = 'user profile path' },
            @{ Text = "token=$fakeToken2"; Why = 'token shape' },
            @{ Text = "contains $marker here"; Why = 'forbidden literal' }
        )
        foreach ($case in $cases) {
            $findings = @(Test-SensitiveLeak -Text $case.Text -ForbidLiterals @($marker))
            if ($findings.Count -eq 0) { throw "detector missed: $($case.Why)" }
        }
        $clean = @(Test-SensitiveLeak -Text 'status=completed exit=0 sha256=abc123 %USERPROFILE%' -ForbidLiterals @($marker))
        if ($clean.Count -ne 0) { throw "detector false-alarmed on clean text: $($clean -join '; ')" }
        'detects path/token/literal, stays quiet on sanitised text'
    }
}
finally {
    Remove-Item $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $repoInside -Recurse -Force -ErrorAction SilentlyContinue
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
$script:Results | Format-Table -AutoSize Id, Status, Title | Out-String -Width 200 | Write-Host
Write-Host ("passed={0}  failed={1}" -f $passed, $failed)

$exitCode = Get-VerificationExitCode -Results $script:Results
Write-Host ("verdict: " + (Get-VerificationExitReason -Results $script:Results))
exit $exitCode
