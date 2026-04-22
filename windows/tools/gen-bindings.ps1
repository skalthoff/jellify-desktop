#requires -Version 7.0
<#
.SYNOPSIS
    Generate C# UniFFI bindings for jellify_core into Jellify.Core/Generated/.

.DESCRIPTION
    Runs `uniffi-bindgen-cs` against a freshly built `jellify_core.dll`. The
    bindgen reads the embedded UniFFI metadata from the DLL itself, so the
    DLL must already exist (run `tools/build-core.ps1` first). Output goes
    to `windows/Jellify.Core/Generated/jellify_core.cs`, which is committed
    so dev machines don't all need uniffi-bindgen-cs installed.

    Install the bindgen once with:

        cargo install uniffi-bindgen-cs `
          --git https://github.com/NordSecurity/uniffi-bindgen-cs `
          --tag v0.10.0+v0.29.4

    The `+v0.29.4` suffix is the upstream UniFFI version this bindgen tracks;
    it must match the `uniffi` crate version in `Cargo.toml`.

.PARAMETER Configuration
    `Debug` (default) or `Release`. Picks which `target/` dir to read the
    DLL from. Match whatever you passed to `tools/build-core.ps1`.

.PARAMETER Architecture
    Which target triple's DLL to read metadata from. `x64` (default) is
    fine on either host since the metadata is identical across triples.

.EXAMPLE
    pwsh windows/tools/gen-bindings.ps1
    Reads target/x86_64-pc-windows-msvc/debug/jellify_core.dll, writes
    windows/Jellify.Core/Generated/jellify_core.cs.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir '..' '..')
$OutDir    = Join-Path $RepoRoot 'windows' 'Jellify.Core' 'Generated'
$Config    = Join-Path $RepoRoot 'windows' 'uniffi.toml'

$Triple = if ($Architecture -eq 'x64') {
    'x86_64-pc-windows-msvc'
}
else {
    'aarch64-pc-windows-msvc'
}

$ProfileDir = if ($Configuration -eq 'Release') { 'release' } else { 'debug' }
$Dll = Join-Path $RepoRoot 'target' $Triple $ProfileDir 'jellify_core.dll'

if (-not (Test-Path $Dll)) {
    throw "Native DLL not found at $Dll. Run windows/tools/build-core.ps1 first."
}

if (-not (Get-Command uniffi-bindgen-cs -ErrorAction SilentlyContinue)) {
    throw @"
uniffi-bindgen-cs is not on PATH. Install with:

  cargo install uniffi-bindgen-cs ``
    --git https://github.com/NordSecurity/uniffi-bindgen-cs ``
    --tag v0.10.0+v0.29.4
"@
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "==> uniffi-bindgen-cs --library $Dll"
Push-Location $RepoRoot
try {
    & uniffi-bindgen-cs `
        --library $Dll `
        --out-dir $OutDir `
        --config $Config
    if ($LASTEXITCODE -ne 0) {
        throw "uniffi-bindgen-cs failed (exit $LASTEXITCODE)"
    }
}
finally {
    Pop-Location
}

Write-Host "==> Done. Bindings written to $OutDir"
