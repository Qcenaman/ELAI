# One-shot desktop setup: llama.cpp -> models -> preset -> firewall -> start hub -> smoke test -> OpenCode.
# Run from an elevated PowerShell (TokenSaver run with elevated:true, or "Run as administrator").
#   .\setup.ps1
#   .\setup.ps1 -SkipModels -SkipOpenCode     # pieces can be skipped and run later on their own
[CmdletBinding()]
param(
    [switch]$SkipLlama,
    [switch]$SkipModels,
    [switch]$SkipFirewall,
    [switch]$SkipOpenCode,
    [switch]$NoStart,
    [string]$Root,
    [string]$ModelsDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "elai-common.ps1")

$settings = Get-ElaiSettings -RootOverride $Root -ModelsDirOverride $ModelsDir
$r = $settings.resolved
Write-Step "ELAI desktop setup - root $($r.Root), models $($r.ModelsDir), port $($r.Port)"
if (-not (Test-IsAdmin)) { Write-Warn "not running as admin: the firewall step will ask for elevation" }

$common = @{}
if ($Root) { $common['Root'] = $Root }

if (-not $SkipLlama) { & (Join-Path $PSScriptRoot "install-llama.ps1") @common }
if (-not $SkipModels) {
    $gm = @{}
    if ($Root) { $gm['Root'] = $Root }
    if ($ModelsDir) { $gm['ModelsDir'] = $ModelsDir }
    & (Join-Path $PSScriptRoot "get-models.ps1") @gm
}
$mp = @{}
if ($Root) { $mp['Root'] = $Root }
if ($ModelsDir) { $mp['ModelsDir'] = $ModelsDir }
& (Join-Path $PSScriptRoot "make-preset.ps1") @mp
if (-not $SkipFirewall) { & (Join-Path $PSScriptRoot "firewall.ps1") @common }
if (-not $SkipOpenCode) { & (Join-Path $PSScriptRoot "install-opencode.ps1") @common }
if (-not $NoStart) {
    & (Join-Path $PSScriptRoot "start-hub.ps1") @common
    & (Join-Path $PSScriptRoot "hub-test.ps1") @common
}
Write-Step "Done. Hub: $($r.BaseUrl)/v1 (models: coder, planner). Launcher for TokenSaver ai_script: $($r.StartCmd)"
