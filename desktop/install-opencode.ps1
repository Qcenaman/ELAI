# Installs OpenCode (standalone Windows build) into <root>\opencode and points it at the hub + TokenSaver.
# Writes/merges the global config: %USERPROFILE%\.config\opencode\opencode.json (existing keys are kept, a .bak is made).
#   .\install-opencode.ps1
#   .\install-opencode.ps1 -ConfigOnly     # only (re)write the config
#   .\install-opencode.ps1 -WithTokenSaver # also give OpenCode the TokenSaver tools (default: ContextSaver only)
#   .\install-opencode.ps1 -HubUrl http://192.168.1.50:8080/v1   # for a second machine
[CmdletBinding()]
param(
    [string]$Root,
    [string]$HubUrl,
    [string]$TokenSaverExe,
    [switch]$WithTokenSaver,
    [string]$ContextSaverExe,
    [string]$ConfigPath,
    [switch]$ConfigOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "elai-common.ps1")

$settings = Get-ElaiSettings -RootOverride $Root
$r = $settings.resolved
$dest = $r.OpenCodeDir

function Set-Prop {
    param($Obj, [string]$Name, $Value)
    Add-Member -InputObject $Obj -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Get-Prop {
    param($Obj, [string]$Name)
    if ($null -ne $Obj -and (Test-Prop $Obj $Name)) { return $Obj.$Name }
    return $null
}

function Resolve-SaverExe {
    # TokenSaver / ContextSaver: configured path, the usual install folder, or PATH.
    param([string]$Configured, [string]$AppName)
    if ($Configured -and $Configured -ne 'auto') { if (Test-Path $Configured) { return $Configured } else { return $null } }
    $exe = $AppName.ToLower() + ".exe"
    $candidates = @("D:\Claude Apps\$AppName\app\$exe", "C:\Claude Apps\$AppName\app\$exe")
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command $exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ---- binary ----
if (-not $ConfigOnly) {
    $exe = Join-Path $dest "opencode.exe"
    if ((Test-Path $exe) -and -not $Force) {
        $v = (& $exe --version 2>&1 | Out-String).Trim()
        Write-Step "OpenCode already installed: $v ($exe)"
    } else {
        $url = [string]$settings.opencode.zipUrl
        $zip = Join-Path $r.Root "opencode-windows-x64.zip"
        Write-Step "Downloading OpenCode"
        Write-Note $url
        if (Test-Path $zip) { Remove-Item $zip -Force }
        Invoke-Download -Url $url -OutFile $zip -Quiet
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        Remove-Item $zip -Force
        $found = Get-ChildItem -Path $dest -Recurse -Filter "opencode.exe" | Select-Object -First 1
        if (-not $found) { throw "opencode.exe not found in the downloaded zip" }
        if ($found.DirectoryName -ne $dest) {
            Get-ChildItem -Path $found.DirectoryName | Move-Item -Destination $dest -Force
        }
        $v = (& $exe --version 2>&1 | Out-String).Trim()
        Write-Step "OpenCode installed: $v"
    }

    # PATH (user) so 'opencode' works in any new terminal
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }
    $parts = @($userPath.Split(';') | Where-Object { $_ })
    if (-not ($parts | Where-Object { $_.TrimEnd('\') -ieq $dest.TrimEnd('\') })) {
        [Environment]::SetEnvironmentVariable("Path", (($parts + $dest) -join ';'), "User")
        Write-Note "added $dest to the user PATH (open a new terminal to use 'opencode')"
    }
    if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $dest.TrimEnd('\') })) { $env:Path = "$env:Path;$dest" }
}

# ---- config ----
$hub = if ($HubUrl) { $HubUrl } else { "$($r.BaseUrl)/v1" }
# Local AI uses ContextSaver (made for local models); TokenSaver is Claude's and is only added with -WithTokenSaver.
$ts = $null
if ($WithTokenSaver -or $TokenSaverExe) { $ts = if ($TokenSaverExe) { $TokenSaverExe } else { Resolve-SaverExe -Configured ([string]$settings.tokensaver.exe) -AppName "TokenSaver" } }
$csConfigured = if (Test-Prop $settings 'contextsaver') { [string]$settings.contextsaver.exe } else { 'auto' }
$cs = if ($ContextSaverExe) { $ContextSaverExe } else { Resolve-SaverExe -Configured $csConfigured -AppName "ContextSaver" }
$cfgPath = if ($ConfigPath) { $ConfigPath } else { Join-Path (Join-Path $env:USERPROFILE ".config\opencode") "opencode.json" }

$cfgDir = Split-Path -Parent $cfgPath
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }

# The ELAI rules are loaded into every session through "instructions" (keeps OpenCode's own base prompt intact).
$rulesSrc = Join-Path $PSScriptRoot "ELAI-RULES.md"
$rulesDst = Join-Path $cfgDir "ELAI-RULES.md"
Copy-Item -Path $rulesSrc -Destination $rulesDst -Force

$templatePath = Join-Path $PSScriptRoot "opencode.elai.json"
$templateText = Get-Content -Path $templatePath -Raw -Encoding UTF8
$templateText = $templateText.Replace("__HUB_URL__", $hub)
$templateText = $templateText.Replace("__CONTEXTSAVER_EXE__", $(if ($cs) { $cs.Replace('\', '\\') } else { "contextsaver.exe" }))
$templateText = $templateText.Replace("__RULES_FILE__", $rulesDst.Replace('\', '\\'))
$fragment = $templateText | ConvertFrom-Json

if ($r.ApiKey) {
    Set-Prop -Obj $fragment.providers.elai.settings -Name "apiKey" -Value "{env:ELAI_API_KEY}"
}

# Per-slot context for the OpenCode limits (ctx is shared across the slots); disabled models are hidden.
foreach ($name in (Get-ModelNames -Settings $settings -All)) {
    $m = $settings.models.$name
    $entry = Get-Prop $fragment.providers.elai.models $name
    if ($entry -and (Test-Prop $m 'enabled') -and -not [bool]$m.enabled) { Set-Prop -Obj $entry -Name "disabled" -Value $true }
    if ($entry -and (Get-Prop $m 'ctx') -and (Get-Prop $m 'slots')) {
        $per = [int]([int]$m.ctx / [int]$m.slots)
        Set-Prop -Obj $entry.limit -Name "context" -Value $per
        $out = [math]::Min(32768, [int]($per / 4))
        Set-Prop -Obj $entry.limit -Name "output" -Value $out
    }
}

$existing = $null
if (Test-Path $cfgPath) {
    try { $existing = Get-Content -Path $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Warn "existing $cfgPath is not valid JSON; it will be backed up and replaced" }
    Copy-Item -Path $cfgPath -Destination ($cfgPath + ".bak") -Force
}
$jsonc = Join-Path $cfgDir "opencode.jsonc"
if (Test-Path $jsonc) { Write-Warn "an opencode.jsonc also exists next to the config; OpenCode may prefer it - merge by hand if the hub does not show up" }

if ($null -eq $existing) { $existing = [pscustomobject]@{} }
Set-Prop -Obj $existing -Name '$schema' -Value 'https://opencode.ai/config.json'
Set-Prop -Obj $existing -Name 'model' -Value $fragment.model
Set-Prop -Obj $existing -Name 'default_agent' -Value $fragment.default_agent

if ($null -eq (Get-Prop $existing 'providers')) { Set-Prop -Obj $existing -Name 'providers' -Value ([pscustomobject]@{}) }
Set-Prop -Obj $existing.providers -Name 'elai' -Value $fragment.providers.elai

if ($null -eq (Get-Prop $existing 'mcp')) { Set-Prop -Obj $existing -Name 'mcp' -Value ([pscustomobject]@{}) }
if ($null -eq (Get-Prop $existing.mcp 'servers')) { Set-Prop -Obj $existing.mcp -Name 'servers' -Value ([pscustomobject]@{}) }
if ($ts) {
    Set-Prop -Obj $existing.mcp.servers -Name 'tokensaver' -Value ([pscustomobject]@{ type = 'local'; command = @($ts, 'mcp'); timeout = [pscustomobject]@{ startup = 60000 } })
} elseif ($null -ne (Get-Prop $existing.mcp.servers 'tokensaver')) {
    $existing.mcp.servers.PSObject.Properties.Remove('tokensaver')
    Write-Note "removed tokensaver from OpenCode's MCP servers (local AI uses ContextSaver)"
}
if ($cs) {
    Set-Prop -Obj $existing.mcp.servers -Name 'contextsaver' -Value $fragment.mcp.servers.contextsaver
} else {
    Write-Warn "ContextSaver not found (looked in D:\Claude Apps\ContextSaver\app and PATH); OpenCode gets no MCP tools. Re-run with -ContextSaverExe <path>."
}

if ($null -eq (Get-Prop $existing 'agents')) { Set-Prop -Obj $existing -Name 'agents' -Value ([pscustomobject]@{}) }
foreach ($a in $fragment.agents.PSObject.Properties) { Set-Prop -Obj $existing.agents -Name $a.Name -Value $a.Value }

# instructions: keep whatever is there, make sure the ELAI rules file is listed once
$instr = @()
$cur = Get-Prop $existing 'instructions'
if ($null -ne $cur) { $instr = @($cur | Where-Object { $_ -and ($_ -notlike '*ELAI-RULES.md') }) }
$instr += $rulesDst
Set-Prop -Obj $existing -Name 'instructions' -Value @($instr)

$json = $existing | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText($cfgPath, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Step "OpenCode config written: $cfgPath"
Write-Note "hub: $hub"
Write-Note ("contextsaver: " + $(if ($cs) { $cs } else { "(not configured)" }))
if ($ts) { Write-Note "tokensaver: $ts" }
Write-Note "rules: $rulesDst"
Write-Note "default model elai/coder (agent elai-coder); elai/coder#fast = thinking off"
