<#
.SYNOPSIS
    Audits Windows DHCP scope utilization and flags scopes approaching exhaustion.

.DESCRIPTION
    Automates the "monitor lease utilization, set alerts for exhaustion" recommendation
    from ip-assignement-best-practices/readme.md. Pulls utilization statistics for every
    scope on a DHCP server (or a specific scope) and flags anything above a configurable
    threshold -- the same signal that, left unmonitored, produces the DHCP-exhaustion /
    APIPA fallback failure documented in the companion case study
    (dhcp-lease-time-&-ip-exhaustion).

.PARAMETER ComputerName
    The DHCP server to query. Defaults to the local machine.

.PARAMETER ScopeId
    Optional. Check a single scope (e.g. 10.10.20.0) instead of all scopes on the server.

.PARAMETER WarningThresholdPercent
    Utilization percentage at which a scope is flagged. Default: 80.

.PARAMETER CriticalThresholdPercent
    Utilization percentage at which a scope is flagged as critical. Default: 90.

.EXAMPLE
    .\Check-DhcpScopeUtilization.ps1

    Checks all scopes on the local DHCP server using default thresholds.

.EXAMPLE
    .\Check-DhcpScopeUtilization.ps1 -ComputerName dhcp01.lab.lan -WarningThresholdPercent 75 -CriticalThresholdPercent 85

    Checks a remote DHCP server with custom thresholds.

.EXAMPLE
    .\Check-DhcpScopeUtilization.ps1 -ScopeId 10.10.20.0

    Checks a single scope only.

.NOTES
    Requires the DhcpServer PowerShell module (built into Windows Server with the
    DHCP Server role, or installable via RSAT on an admin workstation:
    Install-WindowsFeature RSAT-DHCP  /  Add-WindowsCapability -Online -Name Rsat.DHCP.Tools*)
    Run with an account that has DHCP read permissions on the target server.
#>

[CmdletBinding()]
param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [string]$ScopeId,
    [int]$WarningThresholdPercent = 80,
    [int]$CriticalThresholdPercent = 90
)

if (-not (Get-Module -ListAvailable -Name DhcpServer)) {
    Write-Error "The DhcpServer module isn't available on this machine. Install RSAT DHCP tools or run this on the DHCP server itself."
    exit 2
}
Import-Module DhcpServer -ErrorAction Stop

try {
    if ($ScopeId) {
        $scopes = Get-DhcpServerv4Scope -ComputerName $ComputerName -ScopeId $ScopeId -ErrorAction Stop
    } else {
        $scopes = Get-DhcpServerv4Scope -ComputerName $ComputerName -ErrorAction Stop
    }
} catch {
    Write-Error "Could not query DHCP server '$ComputerName': $_"
    exit 2
}

if (-not $scopes) {
    Write-Warning "No scopes found on $ComputerName."
    exit 0
}

$report = foreach ($scope in $scopes) {
    $stats = Get-DhcpServerv4ScopeStatistics -ComputerName $ComputerName -ScopeId $scope.ScopeId

    $status = "OK"
    if ($stats.PercentageInUse -ge $CriticalThresholdPercent) {
        $status = "CRITICAL"
    } elseif ($stats.PercentageInUse -ge $WarningThresholdPercent) {
        $status = "WARNING"
    }

    [PSCustomObject]@{
        ScopeId          = $scope.ScopeId
        Name             = $scope.Name
        State            = $scope.State
        AddressesFree    = $stats.Free
        AddressesInUse   = $stats.InUse
        PercentageInUse  = [math]::Round($stats.PercentageInUse, 1)
        Status           = $status
    }
}

$report | Sort-Object PercentageInUse -Descending | Format-Table -AutoSize

$warnings  = $report | Where-Object { $_.Status -eq "WARNING" }
$criticals = $report | Where-Object { $_.Status -eq "CRITICAL" }

if ($criticals) {
    Write-Host "`n❌ $($criticals.Count) scope(s) at CRITICAL utilization (>= $CriticalThresholdPercent%) -- exhaustion risk, plan a scope expansion or lease-time reduction now." -ForegroundColor Red
}
if ($warnings) {
    Write-Host "⚠️  $($warnings.Count) scope(s) at WARNING utilization (>= $WarningThresholdPercent%) -- worth planning ahead of time." -ForegroundColor Yellow
}
if (-not $criticals -and -not $warnings) {
    Write-Host "`n✅ All scopes within healthy utilization." -ForegroundColor Green
}

if ($criticals) { exit 1 } else { exit 0 }
