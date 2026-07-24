<#
.SYNOPSIS
    Detects hosts that have fallen back to an APIPA address (169.254.x.x) --
    the first diagnostic signal in dhcp-lease-time-&-ip-exhaustion.md.

.DESCRIPTION
    The case study's diagnosis started with noticing devices carrying
    169.254.x.x addresses -- a sign of DHCP failure, NIC/TCP-IP stack issues,
    or pool exhaustion. This script automates that detection two ways:

    1. Local ARP-cache check (fast, no network scanning): flags any neighbor
       entry already showing an APIPA address.
    2. Active subnet sweep (optional, -Sweep): pings every host in a given
       subnet and reports which ones respond from -- or fail to get past --
       an APIPA address, which is a stronger signal of an active DHCP problem
       right now rather than a stale ARP entry.

.PARAMETER Sweep
    If set, actively pings every address in -SubnetCidr instead of only
    reading the existing ARP cache.

.PARAMETER SubnetCidr
    The subnet to sweep, e.g. 10.10.20.0/24. Required when -Sweep is used.

.EXAMPLE
    .\Find-ApipaHosts.ps1

    Checks the local ARP cache only (safe, fast, read-only).

.EXAMPLE
    .\Find-ApipaHosts.ps1 -Sweep -SubnetCidr 10.10.20.0/24

    Actively pings the whole subnet first (populating the ARP cache), then
    reports every host that answered from an APIPA address.

.NOTES
    Run with sufficient privilege to read the neighbor/ARP table
    (Get-NetNeighbor). No changes are made to the network or to DHCP --
    this is a read-only diagnostic tool.
#>

[CmdletBinding()]
param(
    [switch]$Sweep,
    [string]$SubnetCidr
)

function Get-HostsInCidr {
    param([string]$Cidr)
    $parts = $Cidr -split '/'
    $ip = [System.Net.IPAddress]::Parse($parts[0])
    $prefixLength = [int]$parts[1]

    $ipBytes = $ip.GetAddressBytes()
    [Array]::Reverse($ipBytes)
    $ipInt = [BitConverter]::ToUInt32($ipBytes, 0)

    $maskInt = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefixLength))
    $networkInt = $ipInt -band $maskInt
    $broadcastInt = $networkInt -bor (-bnot $maskInt -band 0xFFFFFFFF)

    $hostCount = $broadcastInt - $networkInt - 1
    if ($hostCount -le 0) { return @() }

    1..$hostCount | ForEach-Object {
        $hostInt = $networkInt + $_
        $bytes = [BitConverter]::GetBytes([uint32]$hostInt)
        [Array]::Reverse($bytes)
        [System.Net.IPAddress]::new($bytes).ToString()
    }
}

if ($Sweep) {
    if (-not $SubnetCidr) {
        Write-Error "-SubnetCidr is required when using -Sweep (e.g. -SubnetCidr 10.10.20.0/24)"
        exit 2
    }
    Write-Host "Sweeping $SubnetCidr -- this populates the ARP cache for every responsive host..." -ForegroundColor Cyan
    $targets = Get-HostsInCidr -Cidr $SubnetCidr
    $targets | ForEach-Object -Parallel {
        Test-Connection -TargetName $_ -Count 1 -TimeoutSeconds 1 -ErrorAction SilentlyContinue | Out-Null
    } -ThrottleLimit 32
}

$neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like "169.254.*" }

if (-not $neighbors) {
    Write-Host "✅ No APIPA-addressed hosts found $(if ($Sweep) { "in $SubnetCidr" } else { "in the local ARP cache" })." -ForegroundColor Green
    exit 0
}

Write-Host "❌ $($neighbors.Count) host(s) found with APIPA addresses:" -ForegroundColor Red
$neighbors |
    Select-Object IPAddress, LinkLayerAddress, State, InterfaceAlias |
    Format-Table -AutoSize

Write-Host "This matches the diagnostic signal from the case study: APIPA presence usually means DHCP is unreachable, exhausted, or the client's TCP/IP stack failed to renew a lease. Check DHCP server health and scope utilization next (see Check-DhcpScopeUtilization.ps1)." -ForegroundColor Yellow
exit 1
