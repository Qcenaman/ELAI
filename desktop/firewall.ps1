# Opens the hub port in Windows Firewall for the home LAN and Tailscale (needs admin; self-elevates if not).
#   .\firewall.ps1            # add/replace the rule
#   .\firewall.ps1 -Remove    # remove it
[CmdletBinding()]
param(
    [switch]$Remove,
    [string]$Root
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "elai-common.ps1")

$settings = Get-ElaiSettings -RootOverride $Root
$port = $settings.resolved.Port
$ruleName = "ELAI hub (llama-server $port)"

if (-not (Test-IsAdmin)) {
    Write-Step "Elevation needed for the firewall rule; asking Windows"
    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Remove) { $args += "-Remove" }
    if ($Root) { $args += @("-Root", "`"$Root`"") }
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $args -Verb RunAs -Wait -PassThru
    exit $p.ExitCode
}

Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Remove) {
    Write-Step "Removed firewall rule '$ruleName'"
    exit 0
}

# LocalSubnet = home LAN; 100.64.0.0/10 = Tailscale. Any profile, so it also works when Windows calls the Wi-Fi 'Public'.
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port `
    -RemoteAddress @("LocalSubnet", "100.64.0.0/10") -Profile Any -Description "ELAI local AI hub (llama-server router)" | Out-Null
Write-Step "Firewall rule '$ruleName' added: TCP $port from the LAN and Tailscale"
