# Shared helpers for the ELAI desktop scripts. Dot-source this file; do not run it directly.
# Works on Windows PowerShell 5.1 and PowerShell 7.

Set-StrictMode -Version 2.0

$script:ElaiDesktopDir = $PSScriptRoot

function Test-Prop {
    # True when $Obj has a property called $Name (works on empty objects under strict mode).
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $false }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj.Contains($Name) }
    return ($null -ne $Obj.PSObject.Properties[$Name])
}

function Write-Step {
    param([string]$Message)
    Write-Host ("==> " + $Message) -ForegroundColor Cyan
}

function Write-Note {
    param([string]$Message)
    Write-Host ("    " + $Message) -ForegroundColor DarkGray
}

function Write-Warn {
    param([string]$Message)
    Write-Host ("!!  " + $Message) -ForegroundColor Yellow
}

# $IsWindows only exists on PowerShell 6+; 5.1 is always Windows.
$script:IsWindowsHost = $true
if ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) {
    $script:IsWindowsHost = [bool](Get-Variable -Name IsWindows -ValueOnly)
}

function Test-IsAdmin {
    if (-not $script:IsWindowsHost) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ElaiSettingsPath {
    return (Join-Path $script:ElaiDesktopDir "elai.json")
}

function Resolve-ElaiRoot {
    param([string]$Configured)
    if ($Configured -and $Configured -ne "auto") { return $Configured }
    if (Test-Path "D:\") { return "D:\ELAI" }
    return "C:\ELAI"
}

function Resolve-ModelsDir {
    param(
        [string]$Configured,
        [string]$Root,
        [string[]]$Candidates = @("D:\llama.cpp\models", "D:\models", "D:\ELAI\models")
    )
    if ($Configured -and $Configured -ne "auto") { return $Configured }
    foreach ($c in $Candidates) {
        if (Test-Path $c -PathType Container) { return $c }
    }
    return (Join-Path $Root "models")
}

function Get-ElaiSettings {
    param(
        [string]$Path = (Get-ElaiSettingsPath),
        [string]$RootOverride,
        [string]$ModelsDirOverride
    )
    if (-not (Test-Path $Path)) { throw "Settings file not found: $Path" }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $s = $raw | ConvertFrom-Json

    $root = if ($RootOverride) { $RootOverride } else { Resolve-ElaiRoot -Configured $s.root }
    $modelsDir = if ($ModelsDirOverride) { $ModelsDirOverride } else { Resolve-ModelsDir -Configured $s.modelsDir -Root $root }

    $resolved = [ordered]@{
        Root        = $root
        ModelsDir   = $modelsDir
        LlamaDir    = (Join-Path $root "llama")
        OpenCodeDir = (Join-Path $root "opencode")
        LogsDir     = (Join-Path $root "logs")
        PresetPath  = (Join-Path $root "models.ini")
        StartCmd    = (Join-Path $root "start-hub.cmd")
        Host        = $s.host
        Port        = [int]$s.port
        ApiKey      = [string]$s.apiKey
        BaseUrl     = ("http://127.0.0.1:" + [int]$s.port)
    }
    Add-Member -InputObject $s -MemberType NoteProperty -Name resolved -Value ([pscustomobject]$resolved) -Force
    return $s
}

function Get-ModelNames {
    param($Settings)
    return @($Settings.models.PSObject.Properties | ForEach-Object { $_.Name })
}

function Find-ModelFile {
    # Looks for a model file in the models dir, then in the usual alternatives.
    param(
        [string]$FileName,
        [string]$ModelsDir,
        [string[]]$AlsoLook = @("D:\llama.cpp\models", "D:\models", "D:\ELAI\models", "C:\ELAI\models")
    )
    $dirs = @($ModelsDir) + $AlsoLook
    foreach ($d in $dirs) {
        if (-not $d) { continue }
        $p = Join-Path $d $FileName
        if (Test-Path $p -PathType Leaf) { return (Resolve-Path $p).Path }
    }
    return $null
}

function Get-LlamaServer {
    # Returns @{ Exe = <path>; Prefix = @(<args before the server args>) } or $null.
    param([string]$LlamaDir)
    $srv = Join-Path $LlamaDir "llama-server.exe"
    if (Test-Path $srv) { return @{ Exe = $srv; Prefix = @() } }
    $uni = Join-Path $LlamaDir "llama.exe"
    if (Test-Path $uni) { return @{ Exe = $uni; Prefix = @("serve") } }
    # Linux/mac builds (only used by the tests)
    $srvNix = Join-Path $LlamaDir "llama-server"
    if (Test-Path $srvNix) { return @{ Exe = $srvNix; Prefix = @() } }
    return $null
}

function Get-FreeSpaceBytes {
    param([string]$PathOnDrive)
    $qualifier = Split-Path -Path $PathOnDrive -Qualifier -ErrorAction SilentlyContinue
    if (-not $qualifier) { return [long]::MaxValue }
    $drive = Get-PSDrive -Name ($qualifier.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($drive -and (Test-Prop $drive 'Free') -and ($null -ne $drive.Free)) { return [long]$drive.Free }
    return [long]::MaxValue
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N0} MB" -f ($Bytes / 1MB)) }
    return ("{0:N0} B" -f $Bytes)
}

function Get-CurlExe {
    $c = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Invoke-Download {
    # Resumable download with curl.exe when available, Invoke-WebRequest otherwise.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [switch]$Quiet
    )
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $curl = Get-CurlExe
    if ($curl) {
        $args = @("-L", "--fail", "--retry", "10", "--retry-all-errors", "--retry-delay", "5", "-C", "-", "-o", $OutFile, $Url)
        if ($Quiet) { $args = @("-sS") + $args } else { $args = @("--progress-bar") + $args }
        & $curl @args
        if ($LASTEXITCODE -ne 0) { throw "curl failed ($LASTEXITCODE) for $Url" }
        return
    }
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    } finally {
        $ProgressPreference = $old
    }
}

function Get-RemoteSize {
    # Content-Length after redirects, or -1 when unknown.
    param([string]$Url)
    try {
        $curl = Get-CurlExe
        if ($curl) {
            $out = & $curl -sSIL $Url 2>$null
            $sizes = @($out | Where-Object { $_ -match '^(?i)content-length:\s*(\d+)' } | ForEach-Object { [long]$matches[1] })
            if ($sizes.Count -gt 0) { return $sizes[$sizes.Count - 1] }
            return -1
        }
        $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -MaximumRedirection 10
        if ($resp.Headers['Content-Length']) { return [long]$resp.Headers['Content-Length'] }
    } catch { }
    return -1
}

function Invoke-HubApi {
    # Small JSON helper against the hub. Returns the parsed body or throws.
    param(
        [string]$BaseUrl,
        [string]$Path,
        [string]$Method = "GET",
        $Body = $null,
        [string]$ApiKey = "",
        [int]$TimeoutSec = 600
    )
    $headers = @{}
    if ($ApiKey) { $headers['Authorization'] = "Bearer $ApiKey" }
    $params = @{ Uri = ($BaseUrl.TrimEnd('/') + $Path); Method = $Method; TimeoutSec = $TimeoutSec; UseBasicParsing = $true }
    if ($headers.Count -gt 0) { $params['Headers'] = $headers }
    if ($null -ne $Body) {
        $params['ContentType'] = 'application/json'
        $params['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }
    $resp = Invoke-WebRequest @params
    if ($resp.Content) { return ($resp.Content | ConvertFrom-Json) }
    return $null
}

function Wait-HubHealthy {
    param([string]$BaseUrl, [int]$TimeoutSec = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri ($BaseUrl.TrimEnd('/') + "/health") -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) { return $true }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-HubModelStatus {
    # Router mode: GET /models lists presets with their status (loaded/loading/unloaded...).
    param([string]$BaseUrl, [string]$ApiKey = "")
    $r = Invoke-HubApi -BaseUrl $BaseUrl -Path "/models" -ApiKey $ApiKey -TimeoutSec 30
    $out = @()
    foreach ($m in @($r.data)) {
        $status = ""
        if (Test-Prop $m 'status') {
            if ($m.status -is [string]) {
                $status = $m.status
            } elseif ($null -ne $m.status) {
                $status = [string]$m.status.value
                if ((Test-Prop $m.status 'failed') -and $m.status.failed) { $status += " (failed)" }
            }
        }
        $out += [pscustomobject]@{ id = $m.id; status = $status }
    }
    return $out
}
