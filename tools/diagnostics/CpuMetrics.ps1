Set-StrictMode -Version Latest

# CPU percentages are normalized to one logical processor unless explicitly
# divided by the machine's logical processor count. Null means unavailable.
function Get-CpuDeltaPercent($PreviousMs, $CurrentMs, $ElapsedMs) {
    if ($null -eq $PreviousMs -or $null -eq $CurrentMs -or $null -eq $ElapsedMs) { return $null }
    $a = [double]$PreviousMs; $b = [double]$CurrentMs; $dt = [double]$ElapsedMs
    if (-not [double]::IsFinite($a) -or -not [double]::IsFinite($b) -or -not [double]::IsFinite($dt) -or
        $a -lt 0 -or $b -lt $a -or $dt -le 0) { return $null }
    return 100.0 * ($b - $a) / $dt
}

function Get-ThreadCpuDelta($Previous, $Current, $ElapsedMs) {
    if ($null -eq $Previous -or $null -eq $Current -or
        $null -eq $Previous.startTicks -or $null -eq $Current.startTicks -or
        $Previous.startTicks -ne $Current.startTicks) { return $null }
    Get-CpuDeltaPercent $Previous.cpuMs $Current.cpuMs $ElapsedMs
}

function Get-CpuTopologySummary {
    # CIM reports physical core and logical counts per socket, not CCD masks.
    # Native group counts are independent of the current process affinity.
    if (-not ('VictoryCpuGroups' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class VictoryCpuGroups {
    [DllImport("kernel32.dll")] public static extern ushort GetActiveProcessorGroupCount();
    [DllImport("kernel32.dll")] public static extern uint GetActiveProcessorCount(ushort group);
}
'@
    }
    $groups = @()
    for ($i = 0; $i -lt [VictoryCpuGroups]::GetActiveProcessorGroupCount(); $i++) {
        $groups += [pscustomobject]@{ group = $i; logical = [VictoryCpuGroups]::GetActiveProcessorCount([uint16]$i) }
    }
    $cores = $null
    try {
        $sockets = @(Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec 3 -ErrorAction Stop)
        if ($sockets.Count -gt 0 -and @($sockets | Where-Object { $_.NumberOfCores -le 0 }).Count -eq 0) {
            $cores = ($sockets | Measure-Object NumberOfCores -Sum).Sum
        }
    } catch { }
    [pscustomobject]@{
        logical = ($groups | Measure-Object logical -Sum).Sum
        physicalCores = $cores
        groups = $groups
    }
}
