# Read-only, opt-in, bounded Windows process telemetry. JSON lines on stdout.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId,
    [ValidateRange(2,3600)][int]$Samples = 30,
    [ValidateRange(250,10000)][int]$IntervalMs = 1000,
    [ValidateRange(1,4096)][int]$MaxThreads = 512,
    [switch]$PerLogicalProcessor
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'CpuMetrics.ps1')
if (-not $IsWindows) { throw 'Windows PowerShell 7+ is required.' }
$target = [Diagnostics.Process]::GetProcessById($ProcessId)
try {
    $identity = $target.StartTime.ToUniversalTime().Ticks
    $topology = Get-CpuTopologySummary
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $previous = @{}
    $previousMs = $null
    $previousAt = $null
    for ($i = 0; $i -lt $Samples; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds $IntervalMs }
        $target.Refresh()
        if ($target.HasExited -or $target.StartTime.ToUniversalTime().Ticks -ne $identity) { break }
        $at = $clock.Elapsed.TotalMilliseconds
        $utc = [DateTime]::UtcNow.ToString('o')
        $cpu = $target.TotalProcessorTime.TotalMilliseconds
        $dt = if ($null -ne $previousAt) { $at - $previousAt } else { $null }
        $percent = Get-CpuDeltaPercent $previousMs $cpu $dt
        $threads = $target.Threads
        $threadCount = $threads.Count
        $current = @{}
        $threadRows = @()
        try {
            foreach ($thread in $threads) {
                if ($threadRows.Count -ge $MaxThreads) { break }
                $id = $thread.Id
                $start = $null; $used = $null
                try { $start = $thread.StartTime.ToUniversalTime().Ticks } catch { }
                try { $used = $thread.TotalProcessorTime.TotalMilliseconds } catch { }
                $entry = @{ startTicks = $start; cpuMs = $used }
                $current[$id] = $entry
                $threadRows += [pscustomobject]@{
                    id = $id; cpuTimeMs = $used
                    cpuPercentOneLogical = Get-ThreadCpuDelta $previous[$id] $entry $dt
                }
            }
        } finally {
            foreach ($thread in $threads) { $thread.Dispose() }
        }
        $perCore = $null
        if ($PerLogicalProcessor) {
            try {
                $perCore = @(Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -OperationTimeoutSec 3 -ErrorAction Stop |
                    Where-Object { $_.Name -match '^\d+,\d+$' } |
                    ForEach-Object { [pscustomobject]@{ groupAndLogical = $_.Name; busyPercent = $_.PercentProcessorTime } })
                if ($perCore.Count -eq 0) { $perCore = $null }
            } catch { $perCore = $null }
        }
        [pscustomobject]@{
            schema = 'victory.cpu.sample.v1'; utc = $utc; elapsedMs = $at; intervalMs = $dt
            processId = $ProcessId; processStartUtcTicks = $identity
            cpuTimeMs = $cpu; cpuPercentOneLogical = $percent
            cpuPercentMachine = if ($null -ne $percent -and $topology.logical -gt 0) { $percent / $topology.logical } else { $null }
            topology = $topology; threadCount = $threadCount; threadsTruncated = ($threadCount -gt $MaxThreads)
            threads = $threadRows; logicalProcessorBusy = $perCore
            clockMHz = $null; temperatureC = $null; powerW = $null; cacheMisses = $null
        } | ConvertTo-Json -Depth 6 -Compress
        $previous = $current; $previousMs = $cpu; $previousAt = $at
    }
} finally { $target.Dispose() }
