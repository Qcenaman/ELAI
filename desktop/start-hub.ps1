# Starts the ELAI hub (llama-server router with both models) and waits until the models are loaded.
#   .\start-hub.ps1              # new console window (keeps running after this script ends)
#   .\start-hub.ps1 -Foreground  # run in this console (Ctrl+C stops it)
#   .\start-hub.ps1 -NoWait      # do not wait for the models to load
[CmdletBinding()]
param(
    [switch]$Foreground,
    [switch]$NoWait,
    [int]$LoadTimeoutSec = 900,
    [string]$Root
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "elai-common.ps1")

$settings = Get-ElaiSettings -RootOverride $Root
$r = $settings.resolved

if (-not (Test-Path $r.PresetPath) -or -not (Test-Path $r.StartCmd)) {
    Write-Step "Preset or launcher missing; generating"
    & (Join-Path $PSScriptRoot "make-preset.ps1") -Root $r.Root -Quiet
}
if (-not (Get-LlamaServer -LlamaDir $r.LlamaDir)) { throw "llama-server not found in $($r.LlamaDir). Run install-llama.ps1 first." }

# Already up?
$alreadyUp = $false
try {
    $h = Invoke-WebRequest -Uri ($r.BaseUrl + "/health") -UseBasicParsing -TimeoutSec 3
    if ($h.StatusCode -eq 200) { $alreadyUp = $true }
} catch { }

if ($alreadyUp) {
    Write-Step "Something already answers on port $($r.Port) - not starting a second hub"
} elseif ($Foreground) {
    Write-Step "Starting hub in this console (Ctrl+C to stop)"
    & cmd.exe /c $r.StartCmd
    exit $LASTEXITCODE
} else {
    New-Item -ItemType Directory -Path $r.LogsDir -Force | Out-Null
    Write-Step "Starting hub in a new window: $($r.StartCmd)"
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$($r.StartCmd)`"") -WorkingDirectory $r.LlamaDir -WindowStyle Minimized | Out-Null
    if (-not (Wait-HubHealthy -BaseUrl $r.BaseUrl -TimeoutSec 60)) {
        throw "The hub did not answer on $($r.BaseUrl)/health within 60 s. Open the 'ELAI hub' window to see the error."
    }
    Write-Step "Hub answering on $($r.BaseUrl)"
}

if ($NoWait) { exit 0 }

Write-Step "Waiting for models to load (first start reads ~70 GB from disk; this can take several minutes)"
$deadline = (Get-Date).AddSeconds($LoadTimeoutSec)
$last = ""
while ((Get-Date) -lt $deadline) {
    try {
        $st = Get-HubModelStatus -BaseUrl $r.BaseUrl -ApiKey $r.ApiKey
    } catch { Start-Sleep -Seconds 3; continue }
    $wanted = @()
    foreach ($n in (Get-ModelNames -Settings $settings)) {
        $m = $settings.models.$n
        $load = $true
        if (Test-Prop $m 'loadOnStartup') { $load = [bool]$m.loadOnStartup }
        if ($load) { $wanted += $n }
    }
    $line = ($st | ForEach-Object { "$($_.id)=$($_.status)" }) -join "  "
    if ($line -ne $last) { Write-Note $line; $last = $line }
    $loaded = @($st | Where-Object { $wanted -contains $_.id -and $_.status -eq 'loaded' }).Count
    $failed = @($st | Where-Object { $wanted -contains $_.id -and $_.status -match 'fail|error' })
    if ($failed.Count -gt 0) { throw "Model failed to load: $(($failed | ForEach-Object { $_.id }) -join ', '). See the hub window / logs." }
    if ($loaded -ge $wanted.Count) {
        Write-Step "All models loaded: $($wanted -join ', ')"
        exit 0
    }
    Start-Sleep -Seconds 5
}
Write-Warn "Timed out waiting for the models; the hub keeps loading in the background."
exit 2
