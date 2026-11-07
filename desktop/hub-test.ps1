# Smoke test for the ELAI hub: model status, a short chat per model, generation speed, tool calling, VRAM use.
#   .\hub-test.ps1                       # local hub
#   .\hub-test.ps1 -BaseUrl http://192.168.1.50:8080   # from another machine (copy this file + elai-common.ps1 + elai.json)
[CmdletBinding()]
param(
    [string]$BaseUrl,
    [string]$Root,
    [int]$MaxTokens = 200
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "elai-common.ps1")

$settings = Get-ElaiSettings -RootOverride $Root
$r = $settings.resolved
$base = if ($BaseUrl) { $BaseUrl.TrimEnd('/') } else { $r.BaseUrl }
$apiKey = $r.ApiKey
$failures = 0

Write-Step "Hub: $base"
if (-not (Wait-HubHealthy -BaseUrl $base -TimeoutSec 10)) { throw "No hub answering at $base/health" }

$status = Get-HubModelStatus -BaseUrl $base -ApiKey $apiKey
foreach ($m in $status) { Write-Note "$($m.id): $($m.status)" }

function Invoke-Chat {
    param([string]$Model, $Messages, [int]$Max, $Tools = $null, [bool]$Think = $true)
    $body = @{ model = $Model; messages = $Messages; max_tokens = $Max; stream = $false }
    if (-not $Think) { $body['chat_template_kwargs'] = @{ enable_thinking = $false } }
    if ($Tools) { $body['tools'] = $Tools; $body['tool_choice'] = 'auto' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-HubApi -BaseUrl $base -Path "/v1/chat/completions" -Method POST -Body $body -ApiKey $apiKey -TimeoutSec 900
    $sw.Stop()
    $msg = $resp.choices[0].message
    $completion = 0
    if ((Test-Prop $resp 'usage') -and $resp.usage) { $completion = [int]$resp.usage.completion_tokens }
    $tps = $null
    if ((Test-Prop $resp 'timings') -and $resp.timings -and (Test-Prop $resp.timings 'predicted_per_second')) {
        $tps = [double]$resp.timings.predicted_per_second
    } elseif ($completion -gt 0 -and $sw.Elapsed.TotalSeconds -gt 0) {
        $tps = $completion / $sw.Elapsed.TotalSeconds
    }
    $promptTps = $null
    if ((Test-Prop $resp 'timings') -and $resp.timings -and (Test-Prop $resp.timings 'prompt_per_second')) {
        $promptTps = [double]$resp.timings.prompt_per_second
    }
    return [pscustomobject]@{ message = $msg; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); tokens = $completion; tps = $tps; promptTps = $promptTps }
}

$tools = @(@{
    type = 'function'
    function = @{
        name = 'get_weather'
        description = 'Get the current weather for a city'
        parameters = @{ type = 'object'; properties = @{ city = @{ type = 'string' } }; required = @('city') }
    }
})

$results = @()
foreach ($name in (Get-ModelNames -Settings $settings)) {
    $m = $settings.models.$name
    $thinks = (Test-Prop $m 'reasoning') -and [bool]$m.reasoning
    Write-Step "Testing '$name'"
    $row = [pscustomobject]@{ model = $name; load = ''; short = ''; gen_tps = ''; prompt_tps = ''; tool_call = '' }
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $a = Invoke-Chat -Model $name -Max 32 -Think $false -Messages @(@{ role = 'user'; content = 'Reply with exactly: ELAI OK' })
        $sw.Stop()
        $row.load = "$([math]::Round($sw.Elapsed.TotalSeconds,1)) s"
        $text = [string]$a.message.content
        $row.short = $text.Trim()
        Write-Note ("reply: " + $text.Trim())

        $b = Invoke-Chat -Model $name -Max $MaxTokens -Think $thinks -Messages @(@{ role = 'user'; content = 'Write a Python function that parses a CSV line into a list of fields, handling quoted commas. Code only.' })
        if ($null -ne $b.tps) { $row.gen_tps = ("{0:N1}" -f $b.tps) }
        if ($null -ne $b.promptTps) { $row.prompt_tps = ("{0:N0}" -f $b.promptTps) }
        Write-Note ("$($b.tokens) tokens in $($b.seconds) s" + $(if ($null -ne $b.tps) { " = $("{0:N1}" -f $b.tps) tok/s" } else { "" }))

        $c = Invoke-Chat -Model $name -Max 256 -Think $false -Tools $tools -Messages @(@{ role = 'user'; content = 'What is the weather in Manila right now? Use the tool.' })
        $calls = @()
        if ((Test-Prop $c.message 'tool_calls') -and $c.message.tool_calls) { $calls = @($c.message.tool_calls) }
        if ($calls.Count -gt 0 -and $calls[0].function.name -eq 'get_weather') {
            $row.tool_call = 'ok'
            Write-Note ("tool call: " + $calls[0].function.name + " " + $calls[0].function.arguments)
        } else {
            $row.tool_call = 'MISSING'
            $failures++
            Write-Warn "no tool call returned (content: $([string]$c.message.content))"
        }
    } catch {
        $failures++
        $row.short = "ERROR: " + $_.Exception.Message
        Write-Warn $_.Exception.Message
    }
    $results += $row
}

Write-Host ""
$results | Format-Table -AutoSize | Out-String | Write-Host

$smi = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
if ($smi) {
    $gpu = & $smi.Source --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>$null
    if ($gpu) { Write-Step "GPU: $gpu" }
}

try {
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { $_.IPAddress })
    if ($ips.Count -gt 0) {
        Write-Step ("Reach the hub from other devices at: " + (($ips | ForEach-Object { "http://${_}:$($r.Port)/v1" }) -join "  "))
    }
} catch { }

if ($failures -gt 0) { Write-Warn "$failures problem(s) found"; exit 1 }
Write-Step "Hub OK"
