<#
.SYNOPSIS
    Installs the pinned Spec Kit CLI (`specify`) into an isolated Python venv.

.DESCRIPTION
    DevRelay does not vendor Spec Kit. This script creates (or reuses) a venv
    outside the repository so the repo stays free of interpreter artefacts, and
    installs an exact `specify-cli` version.

    Prerequisites: Python 3.11+ on PATH (the CLI itself is pure Python; Node.js is
    only needed for Pi).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\setup-specify.ps1

.EXAMPLE
    $env:DEVRELAY_SPECIFY_VERSION = '1.2.1'
    powershell -ExecutionPolicy Bypass -File .\scripts\setup-specify.ps1 -Force
#>
[CmdletBinding()]
param(
    # Exact PyPI version to install. Keep this pinned: P0-02/P0-03 must be re-run
    # before bumping it (see docs/verification/P0-01-P0-03-integration-report.md).
    [string]$Version = $(if ($env:DEVRELAY_SPECIFY_VERSION) { $env:DEVRELAY_SPECIFY_VERSION } else { '1.2.1' }),

    # Where the isolated venv lives. Default keeps it outside the git working tree.
    [string]$ToolsDir = $(if ($env:DEVRELAY_TOOLS_DIR) { $env:DEVRELAY_TOOLS_DIR } else { Join-Path $env:LOCALAPPDATA 'DevRelay\tools' }),

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$venvDir = Join-Path $ToolsDir "specify-venv-$Version"
$python = Join-Path $venvDir 'Scripts\python.exe'
$specify = Join-Path $venvDir 'Scripts\specify.exe'

if ($Force -and (Test-Path $venvDir)) {
    Write-Host "Removing existing venv: $venvDir"
    Remove-Item $venvDir -Recurse -Force
}

if (-not (Test-Path $python)) {
    $hostPython = (Get-Command python -ErrorAction SilentlyContinue)
    if (-not $hostPython) { throw 'python (3.11+) not found on PATH.' }
    $pyVersion = & python -c "import sys;print('%d.%d' % sys.version_info[:2])"
    if ([version]$pyVersion -lt [version]'3.11') { throw "Python 3.11+ required, found $pyVersion" }

    Write-Host "Creating venv: $venvDir (python $pyVersion)"
    & python -m venv $venvDir
    if ($LASTEXITCODE -ne 0) { throw "python -m venv failed (exit $LASTEXITCODE)" }
}

Write-Host "Installing specify-cli==$Version"
& $python -m pip install --disable-pip-version-check --quiet "specify-cli==$Version"
if ($LASTEXITCODE -ne 0) { throw "pip install failed (exit $LASTEXITCODE)" }

Write-Host ''
Write-Host "Installed: $specify"
& $specify version | Select-String -Pattern 'CLI Version|Python|Platform'
Write-Host ''
Write-Host 'Point the verification script at it with:'
Write-Host "  `$env:SPECIFY_BIN = '$specify'"
