#requires -Version 7.0
<#
.SYNOPSIS
    Build jellify_core.dll for Windows x64 and arm64, stage into Jellify.Core/native/.

.DESCRIPTION
    Cross-targets `x86_64-pc-windows-msvc` and `aarch64-pc-windows-msvc` from
    a single host (any Windows machine with Rust + the MSVC toolchain
    installed). Both targets ship a `cdylib` plus its import library; we
    copy each pair into `windows/Jellify.Core/native/{win-x64,win-arm64}/`
    where the csproj picks them up via per-RID `<None>` items.

    Skip arm64 with `-SkipArm64` when iterating locally on an x64 host
    that doesn't have the arm64 target installed; CI installs both.

.PARAMETER Configuration
    `Debug` (default) or `Release`. `Release` builds with LTO + codegen-units=1
    via the workspace `[profile.release]` block.

.PARAMETER SkipArm64
    Skip the arm64 target. Useful for fast iteration on an x64 dev machine.

.EXAMPLE
    pwsh windows/tools/build-core.ps1
    Builds both architectures in Debug.

.EXAMPLE
    pwsh windows/tools/build-core.ps1 -Configuration Release
    Builds both architectures in Release.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    [switch]$SkipArm64
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir '..' '..')
$NativeDir = Join-Path $RepoRoot 'windows' 'Jellify.Core' 'native'

$CargoArgs = @('build', '-p', 'jellify_core')
if ($Configuration -eq 'Release') {
    $CargoArgs += '--release'
}

# Map (cargo target triple) -> (windows RID folder).
$Targets = @(
    @{ Triple = 'x86_64-pc-windows-msvc';  Rid = 'win-x64'   },
    @{ Triple = 'aarch64-pc-windows-msvc'; Rid = 'win-arm64' }
)
if ($SkipArm64) {
    $Targets = $Targets | Where-Object { $_.Rid -ne 'win-arm64' }
}

foreach ($t in $Targets) {
    Write-Host "==> cargo build --target $($t.Triple) ($Configuration)"
    Push-Location $RepoRoot
    try {
        & cargo @CargoArgs --target $t.Triple
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build failed for $($t.Triple)"
        }
    }
    finally {
        Pop-Location
    }

    $ProfileDir = if ($Configuration -eq 'Release') { 'release' } else { 'debug' }
    $SourceDir  = Join-Path $RepoRoot 'target' $t.Triple $ProfileDir
    $DestDir    = Join-Path $NativeDir $t.Rid
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

    foreach ($file in @('jellify_core.dll', 'jellify_core.dll.lib', 'jellify_core.pdb')) {
        $src = Join-Path $SourceDir $file
        if (Test-Path $src) {
            Copy-Item -Force $src $DestDir
            Write-Host "    staged $file -> $DestDir"
        }
        elseif ($file -ne 'jellify_core.pdb') {
            # PDB is debug-only; missing PDB on Release isn't an error.
            throw "Missing $file under $SourceDir after cargo build."
        }
    }
}

Write-Host "==> Done. Native libraries staged under $NativeDir"
