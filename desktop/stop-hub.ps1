# Stops the ELAI hub: the llama-server router started from <root>\llama and its model instances.
# Other llama.cpp servers on the PC (for example D:\llama.cpp) are left alone.
[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "elai-common.ps1")

$settings = Get-ElaiSettings -RootOverride $Root
$r = $settings.resolved
$prefix = $r.LlamaDir.TrimEnd('\') + '\'

$procs = @(Get-CimInstance Win32_Process -Filter "Name = 'llama-server.exe' OR Name = 'llama.exe'" |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })

if ($procs.Count -eq 0) {
    Write-Step "No ELAI hub process running (from $($r.LlamaDir))"
    exit 0
}

# Ask the router to unload first (graceful), then stop the processes.
try {
    foreach ($m in (Get-HubModelStatus -BaseUrl $r.BaseUrl -ApiKey $r.ApiKey)) {
        if ($m.status -eq 'loaded') {
            Invoke-HubApi -BaseUrl $r.BaseUrl -Path "/models/unload" -Method POST -Body @{ model = $m.id } -ApiKey $r.ApiKey -TimeoutSec 30 | Out-Null
        }
    }
    Start-Sleep -Seconds 2
} catch { }

foreach ($p in $procs) {
    Write-Note "stopping pid $($p.ProcessId): $($p.CommandLine)"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
Write-Step "Hub stopped ($($procs.Count) process(es))"
