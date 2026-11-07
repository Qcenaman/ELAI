# Downloads the GGUF models listed in elai.json into the models dir (resumable, skips files already complete).
#   .\get-models.ps1                 # all models
#   .\get-models.ps1 -Only coder     # one model
#   .\get-models.ps1 -ModelsDir D:\models
[CmdletBinding()]
param(
    [string[]]$Only,
    [string]$Root,
    [string]$ModelsDir,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "elai-common.ps1")

$settings = Get-ElaiSettings -RootOverride $Root -ModelsDirOverride $ModelsDir
$r = $settings.resolved
$dir = $r.ModelsDir
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Write-Step "Models dir: $dir"

$names = Get-ModelNames -Settings $settings
if ($Only) { $names = @($names | Where-Object { $Only -contains $_ }) }
if ($names.Count -eq 0) { throw "No models selected. Known: $((Get-ModelNames -Settings $settings) -join ', ')" }

# Build the download list: (repo, file, expected size)
$items = @()
foreach ($n in $names) {
    $m = $settings.models.$n
    $items += [pscustomobject]@{ name = $n; repo = $m.repo; file = $m.file; size = [long]$m.sizeBytes }
    $hasMmproj = (Test-Prop $m 'mmproj') -and $m.mmproj
    $wantsVision = (Test-Prop $m 'vision') -and [bool]$m.vision
    if ($hasMmproj -and $wantsVision) {
        $items += [pscustomobject]@{ name = "$n (vision projector)"; repo = $m.repo; file = $m.mmproj; size = [long]$m.mmprojSizeBytes }
    }
}

# Disk space check (only for files not yet complete).
$need = 0
foreach ($it in $items) {
    $existing = Find-ModelFile -FileName $it.file -ModelsDir $dir
    if ($existing -and -not $Force) { continue }
    $need += $it.size
}
$free = Get-FreeSpaceBytes -PathOnDrive $dir
if ($need -gt 0 -and $free -lt ($need + 2GB)) {
    throw ("Not enough free space on the models drive: need about {0}, free {1}. Change modelsDir in elai.json or free space." -f (Format-Bytes $need), (Format-Bytes $free))
}

foreach ($it in $items) {
    $target = Join-Path $dir $it.file
    $url = "https://huggingface.co/$($it.repo)/resolve/main/$($it.file)?download=true"

    $existing = Find-ModelFile -FileName $it.file -ModelsDir $dir
    if ($existing -and -not $Force) {
        $len = (Get-Item $existing).Length
        $remote = Get-RemoteSize -Url $url
        if ($remote -gt 0 -and $len -ne $remote) {
            Write-Warn "$($it.file) exists at $existing but is $(Format-Bytes $len) (expected $(Format-Bytes $remote)); re-downloading"
            $target = $existing
        } else {
            Write-Step "$($it.name): already present ($(Format-Bytes $len)) at $existing"
            continue
        }
    }

    Write-Step "$($it.name): downloading $($it.file) ($(Format-Bytes $it.size))"
    Write-Note $url
    $part = "$target.part"
    if ($Force -and (Test-Path $part)) { Remove-Item $part -Force }
    Invoke-Download -Url $url -OutFile $part
    $len = (Get-Item $part).Length
    $remote = Get-RemoteSize -Url $url
    if ($remote -gt 0 -and $len -ne $remote) {
        throw "$($it.file): downloaded $len bytes but the server reports $remote. Run again to resume."
    }
    if (Test-Path $target) { Remove-Item $target -Force }
    Move-Item -Path $part -Destination $target
    Write-Note "saved $target"
}

Write-Step "Models ready in $dir"
