<#
.SYNOPSIS
    Shared verification primitives for DevRelay P0 checks.

.DESCRIPTION
    Dot-source this file. Everything here is a pure function over text/objects so
    that `tests\run-negative-tests.ps1` can prove the assertions actually fail on
    bad input (a check that can never fail is not a check).

    Contents:
      * ConvertFrom-WorkflowInfoText  - parse `specify workflow info` output
      * Test-WorkflowInfoStrict       - strict assertions over that output
      * Get-VerificationExitCode      - results -> process exit code
      * Get-VerificationExitReason    - human-readable reason for that code
      * Protect-EvidenceText          - strip personal paths / token shapes
#>

Set-StrictMode -Version 2.0

function ConvertFrom-WorkflowInfoText {
    <#
        Parses the text emitted by `specify workflow info <path|id>`.

        Header:  "<Name> (<workflow-id>)"
        Steps:   "  Steps (5):"
                 "    → identify_business_gap [prompt]"

        Throws when the shape is not recognised, so a parser drift caused by a
        Spec Kit upgrade surfaces as a failed check instead of a silently empty
        step list.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lines = $Text -split "`r?`n"

    $header = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*(?<name>.+?)\s+\((?<id>[A-Za-z0-9][A-Za-z0-9._-]*)\)\s*$') {
            $header = [pscustomobject]@{ Name = $Matches.name.Trim(); WorkflowId = $Matches.id }
            break
        }
    }
    if ($null -eq $header) { throw 'could not parse the workflow name/id header from `specify workflow info`' }

    $declaredCount = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*Steps\s*\((?<n>\d+)\)\s*:') { $declaredCount = [int]$Matches.n; break }
    }
    if ($null -eq $declaredCount) { throw 'could not find the "Steps (N):" section header' }

    $steps = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ($line -match '^\s*[\u2192>-]\s*(?<id>[A-Za-z0-9][A-Za-z0-9._-]*)\s*\[(?<type>[a-z][a-z-]*)\]') {
            [void]$steps.Add([pscustomobject]@{ Id = $Matches.id; Type = $Matches.type })
        }
    }

    [pscustomobject]@{
        Name          = $header.Name
        WorkflowId    = $header.WorkflowId
        DeclaredCount = $declaredCount
        Steps         = @($steps)
    }
}

function Test-WorkflowInfoStrict {
    <#
        Returns an array of problems (empty array == every assertion held).

        Assertions:
          1. the CLI exit code is 0
          2. the workflow id matches
          3. the "Steps (N)" count equals the number of parsed steps
          4. the step id sequence matches exactly (order matters)
          5. the step type sequence matches exactly
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][System.Nullable[int]]$ExitCode,
        [AllowEmptyString()][string]$StdOut = '',
        [AllowEmptyString()][string]$StdErr = '',
        [string[]]$ExpectedStepIds = @(),
        [string[]]$ExpectedStepTypes = @(),
        [string]$ExpectedWorkflowId = ''
    )

    $problems = New-Object System.Collections.ArrayList

    if ($null -eq $ExitCode) {
        [void]$problems.Add('workflow info exit code was not captured')
    } elseif ($ExitCode -ne 0) {
        [void]$problems.Add("workflow info exited with code $ExitCode (expected 0)")
    }

    $combined = "$StdOut`n$StdErr"
    $info = $null
    try {
        $info = ConvertFrom-WorkflowInfoText -Text $combined
    } catch {
        [void]$problems.Add("workflow info output could not be parsed: $($_.Exception.Message)")
        return @($problems)
    }

    if ($ExpectedWorkflowId -and $info.WorkflowId -ne $ExpectedWorkflowId) {
        [void]$problems.Add("workflow id is '$($info.WorkflowId)', expected '$ExpectedWorkflowId'")
    }

    if ($info.DeclaredCount -ne $info.Steps.Count) {
        [void]$problems.Add("header declares $($info.DeclaredCount) steps but $($info.Steps.Count) were parsed")
    }

    if ($ExpectedStepIds.Count -gt 0) {
        $actualIds = @($info.Steps | ForEach-Object { $_.Id })
        if ($actualIds.Count -ne $ExpectedStepIds.Count) {
            [void]$problems.Add("step count is $($actualIds.Count), expected $($ExpectedStepIds.Count) (actual: $($actualIds -join ','))")
        } else {
            for ($i = 0; $i -lt $ExpectedStepIds.Count; $i++) {
                if ($actualIds[$i] -ne $ExpectedStepIds[$i]) {
                    [void]$problems.Add("step $($i + 1) id is '$($actualIds[$i])', expected '$($ExpectedStepIds[$i])'")
                }
            }
        }
    }

    if ($ExpectedStepTypes.Count -gt 0) {
        $actualTypes = @($info.Steps | ForEach-Object { $_.Type })
        if ($actualTypes.Count -ne $ExpectedStepTypes.Count) {
            [void]$problems.Add("step type count is $($actualTypes.Count), expected $($ExpectedStepTypes.Count) (actual: $($actualTypes -join ','))")
        } else {
            for ($i = 0; $i -lt $ExpectedStepTypes.Count; $i++) {
                if ($actualTypes[$i] -ne $ExpectedStepTypes[$i]) {
                    [void]$problems.Add("step $($i + 1) type is '$($actualTypes[$i])', expected '$($ExpectedStepTypes[$i])'")
                }
            }
        }
    }

    return @($problems)
}

function Get-VerificationExitCode {
    <#
        A verification run may only report success when every check actually ran
        AND passed.

        Rules (in order):
          * no checks at all            -> 1 (nothing was proven)
          * any check status 'failed'   -> 1
          * any check status 'not_run'  -> 1 (skipped is not passed)
          * anything other than the two known-good statuses -> 1 (typo guard)
          * otherwise                   -> 0
    #>
    param([AllowNull()][object[]]$Results)

    $all = @($Results | Where-Object { $null -ne $_ })
    if ($all.Count -eq 0) { return 1 }

    if (@($all | Where-Object { $_.Status -eq 'failed' }).Count -gt 0) { return 1 }
    if (@($all | Where-Object { $_.Status -eq 'not_run' }).Count -gt 0) { return 1 }

    $unknown = @($all | Where-Object { $_.Status -ne 'passed' })
    if ($unknown.Count -gt 0) { return 1 }

    return 0
}

function Get-VerificationExitReason {
    param([AllowNull()][object[]]$Results)

    $all = @($Results | Where-Object { $null -ne $_ })
    if ($all.Count -eq 0) { return 'no checks ran: nothing was verified' }

    $failed = @($all | Where-Object { $_.Status -eq 'failed' })
    $notRun = @($all | Where-Object { $_.Status -eq 'not_run' })
    $unknown = @($all | Where-Object { $_.Status -ne 'passed' -and $_.Status -ne 'failed' -and $_.Status -ne 'not_run' })

    $parts = New-Object System.Collections.ArrayList
    if ($failed.Count -gt 0) { [void]$parts.Add("$($failed.Count) failed: $(($failed | ForEach-Object { $_.Id }) -join ', ')") }
    if ($notRun.Count -gt 0) { [void]$parts.Add("$($notRun.Count) not_run (a required check did not execute): $(($notRun | ForEach-Object { $_.Id }) -join ', ')") }
    if ($unknown.Count -gt 0) { [void]$parts.Add("$($unknown.Count) in an unknown status") }
    if ($parts.Count -eq 0) { return 'all checks passed' }

    return ($parts -join '; ')
}

function Protect-EvidenceText {
    <#
        Removes personally identifying paths and anything that looks like a
        credential from text that is about to be written under version control.

        Returns the sanitised string plus a count of replacements so callers can
        report that redaction happened.
    #>
    param([AllowEmptyString()][string]$Text)

    $count = 0
    $result = $Text

    $patterns = @(
        @{ Pattern = '(?i)C:\\Users\\[^\\\s"'']+'; Replacement = '%USERPROFILE%' },
        @{ Pattern = '(?i)/home/[^/\s"'']+';        Replacement = '~' },
        @{ Pattern = '(?i)/Users/[^/\s"'']+';       Replacement = '~' },
        @{ Pattern = 'gh[pous]_[A-Za-z0-9]{16,}';   Replacement = '<redacted-token>' },
        @{ Pattern = 'github_pat_[A-Za-z0-9_]{16,}'; Replacement = '<redacted-token>' },
        @{ Pattern = 'sk-[A-Za-z0-9]{16,}';         Replacement = '<redacted-key>' },
        @{ Pattern = 'AKIA[0-9A-Z]{16}';            Replacement = '<redacted-key>' },
        @{ Pattern = 'xox[baprs]-[A-Za-z0-9-]{10,}'; Replacement = '<redacted-token>' }
    )

    foreach ($p in $patterns) {
        $matches = [regex]::Matches($result, $p.Pattern)
        if ($matches.Count -gt 0) {
            $count += $matches.Count
            $result = [regex]::Replace($result, $p.Pattern, $p.Replacement)
        }
    }

    [pscustomobject]@{ Text = $result; Replacements = $count }
}

function Get-TextDigest {
    <#
        Length + SHA-256 of a string or file, for provenance without content.
    #>
    param(
        [AllowEmptyString()][string]$Text,
        [string]$Path
    )

    if ($PSBoundParameters.ContainsKey('Path')) {
        if (-not (Test-Path $Path)) { return [pscustomobject]@{ Length = 0; Sha256 = '' } }
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $Path).Path)
    } else {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    [pscustomobject]@{ Length = $bytes.Length; Sha256 = $hash }
}
