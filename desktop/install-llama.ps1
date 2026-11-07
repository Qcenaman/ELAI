# Installs a pinned llama.cpp nightly build (Windows, CUDA first) into <root>\llama.
# Self-contained: cpu zip (programs) + backend zip (ggml-cuda.dll) + cudart zip (CUDA runtime), no CUDA Toolkit needed.
#   .\install-llama.ps1                 # tag + backend order from elai.json
#   .\install-llama.ps1 -Tag latest     # newest nightly
#   .\install-llama.ps1 -Backend vulkan # force a backend
[CmdletBinding()]
param(
    [string]$Tag,
    [string]$Backend,
    [string]$Root,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "elai-common.ps1")

$settings = Get-ElaiSettings -RootOverride $Root
$r = $settings.resolved
$llamaDir = $r.LlamaDir
$tag = if ($Tag) { $Tag } else { [string]$settings.llama.tag }
$backends = if ($Backend) { @($Backend) } else { @($settings.llama.backends) }
$installedJson = Join-Path $llamaDir "installed.json"

function Resolve-LatestNightlyTag {
    $api = "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10"
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try {
        $rel = Invoke-RestMethod -Uri $api -UseBasicParsing -Headers @{ 'User-Agent' = 'ELAI-setup' }
    } finally { $ProgressPreference = $old }
    foreach ($x in $rel) { if ($x.tag_name -match '^b\d+$') { return $x.tag_name } }
    throw "No nightly (bNNNN) release found."
}

function Test-LlamaBuild {
    # Runs --list-devices and returns the output when the build starts, $null otherwise.
    param([string]$Dir, [string]$WantBackend)
    $srv = Get-LlamaServer -LlamaDir $Dir
    if (-not $srv) { return $null }
    try {
        $out = & $srv.Exe @($srv.Prefix + @("--list-devices")) 2>&1 | Out-String
    } catch { return $null }
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($WantBackend -like "cuda*" -and $out -notmatch '(?i)cuda') { return $null }
    if ($WantBackend -like "vulkan*" -and $out -notmatch '(?i)vulkan') { return $null }
    return $out
}

if ($tag -eq "latest") {
    Write-Step "Resolving latest llama.cpp nightly tag"
    $tag = Resolve-LatestNightlyTag
    Write-Note "latest = $tag"
}

if (-not $Force -and (Test-Path $installedJson)) {
    $cur = Get-Content $installedJson -Raw | ConvertFrom-Json
    if ($cur.tag -eq $tag -and (Test-LlamaBuild -Dir $llamaDir -WantBackend $cur.backend)) {
        Write-Step "llama.cpp $tag ($($cur.backend)) already installed in $llamaDir"
        exit 0
    }
}

New-Item -ItemType Directory -Path $r.Root -Force | Out-Null
$tmp = Join-Path $r.Root ("tmp-llama-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$ok = $false
foreach ($b in $backends) {
    Write-Step "Trying llama.cpp $tag, backend $b"
    $assets = Get-LlamaAssets -Tag $tag -Backend $b
    $stage = Join-Path $tmp $b
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $downloaded = $true
    foreach ($a in $assets) {
        $url = "https://github.com/ggml-org/llama.cpp/releases/download/$tag/$a"
        $zip = Join-Path $tmp $a
        try {
            Write-Note "downloading $a"
            Invoke-Download -Url $url -OutFile $zip -Quiet
            Expand-Archive -Path $zip -DestinationPath $stage -Force
        } catch {
            Write-Warn "download/extract failed for $a : $($_.Exception.Message)"
            $downloaded = $false
            break
        }
    }
    if (-not $downloaded) { continue }

    # Flatten a single nested folder (some zips wrap everything in one directory).
    $entries = @(Get-ChildItem -Path $stage)
    if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
        Get-ChildItem -Path $entries[0].FullName | Move-Item -Destination $stage -Force
        Remove-Item $entries[0].FullName -Recurse -Force
    }

    $probe = Test-LlamaBuild -Dir $stage -WantBackend $b
    if (-not $probe) {
        Write-Warn "build $b does not start on this machine (driver too old or no matching GPU); trying the next backend"
        continue
    }

    # Replace the current install.
    if (Test-Path $llamaDir) {
        Get-Process -Name "llama-server", "llama" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($llamaDir, [StringComparison]::OrdinalIgnoreCase) } |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-Item $llamaDir -Recurse -Force
    }
    Move-Item -Path $stage -Destination $llamaDir
    @{ tag = $tag; backend = $b; installedAt = (Get-Date).ToString("s") } | ConvertTo-Json | Set-Content -Path $installedJson -Encoding ASCII
    Write-Step "Installed llama.cpp $tag ($b) to $llamaDir"
    Write-Host ($probe.Trim())
    $ok = $true
    break
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if (-not $ok) { throw "No llama.cpp build worked. Check the NVIDIA driver (CUDA 13.x needs a recent driver) or run with -Backend vulkan." }
