Set-StrictMode -Version Latest
function Get-IoDelta($Before,$After) {
    if ($null -eq $Before -or $null -eq $After -or $Before -lt 0 -or $After -lt $Before) { return $null }
    return [double]($After - $Before)
}
function Get-IoRate($Before,$After,$Seconds) {
    $delta=Get-IoDelta $Before $After
    if ($null -eq $delta -or $null -eq $Seconds -or $Seconds -le 0) { return $null }
    return $delta / $Seconds
}
# PERF_AVERAGE_TIMER: difference in ticks / frequency / difference in base.
function Get-DiskLatencyMs($Previous,$Current,[string]$Operation) {
    if ($null -eq $Previous -or $null -eq $Current) { return $null }
    $n="AvgDisksecPer$Operation"; $b=$n+'_Base'
    $ticks=Get-IoDelta $Previous.$n $Current.$n
    $ops=Get-IoDelta $Previous.$b $Current.$b
    if ($null -eq $ticks -or $null -eq $ops -or $ops -le 0 -or
        $Current.Frequency_PerfTime -le 0 -or $Previous.Frequency_PerfTime -ne $Current.Frequency_PerfTime) { return $null }
    return 1000.0 * $ticks / $Current.Frequency_PerfTime / $ops
}
if (-not ('VictoryStorageCounters' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VictoryStorageCounters {
    [StructLayout(LayoutKind.Sequential)]
    public struct Io {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetProcessIoCounters(IntPtr handle, out Io counters);
}
'@
}
function Get-ProcessIo($Process) {
    $c=[VictoryStorageCounters+Io]::new()
    try {
        if ([VictoryStorageCounters]::GetProcessIoCounters($Process.Handle,[ref]$c)) {
            return [pscustomobject]@{ readBytes=$c.ReadTransferCount; writeBytes=$c.WriteTransferCount
                readOps=$c.ReadOperationCount; writeOps=$c.WriteOperationCount }
        }
    } catch { }
    return $null
}
function Get-PhysicalDiskCounters {
    try {
        @(Get-CimInstance -ClassName Win32_PerfRawData_PerfDisk_PhysicalDisk -OperationTimeoutSec 3 -ErrorAction Stop |
            Where-Object { $_.Name -ne '_Total' })
    } catch { }
}
function Get-ReadBlockIndex([int]$Index,[int]$Blocks,[bool]$RandomOrder) {
    if ($Blocks -lt 1 -or ($Blocks -band ($Blocks-1)) -ne 0 -or $Index -lt 0 -or $Index -ge $Blocks) { throw 'Invalid block layout.' }
    if ($RandomOrder) { return [int](([long]$Index * 7919 + 17) % $Blocks) }
    return $Index
}
