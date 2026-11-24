Set-StrictMode -Version Latest

function Get-RamTrend($Values, [long]$ThresholdBytes = 16777216) {
    # A candidate requires four matched checkpoints, three consecutive
    # nondecreasing intervals, a positive change in each and enough growth.
    $v = @($Values)
    if ($v.Count -lt 4 -or @($v | Where-Object { $null -eq $_ -or $_ -lt 0 }).Count -gt 0) {
        return [pscustomobject]@{ status='insufficient-data'; growthBytes=$null; peakBytes=$null }
    }
    $peak = ($v | Measure-Object -Maximum).Maximum
    $growth = [double]$v[-1] - [double]$v[0]
    $rising = $true
    for ($i=1; $i -lt $v.Count; $i++) {
        if ($v[$i] -le $v[$i-1]) { $rising=$false }
    }
    [pscustomobject]@{
        status=if ($rising -and $growth -ge $ThresholdBytes) {'candidate-growth'} else {'no-sustained-growth'}
        growthBytes=$growth; peakBytes=$peak
    }
}

function Get-MemoryDelta($Previous, $Current) {
    if ($null -eq $Previous -or $null -eq $Current -or $Previous -lt 0 -or $Current -lt $Previous) { return $null }
    [double]$Current - [double]$Previous
}

function Get-SystemRamSnapshot {
    # Win32_PerfRawData_PerfOS_Memory contains cumulative page-read
    # operations, not counts of hard faults in the target process.
    try {
        $m=Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -OperationTimeoutSec 3 -ErrorAction Stop
        [pscustomobject]@{
            availableBytes=$m.AvailableBytes; committedBytes=$m.CommittedBytes
            commitLimitBytes=$m.CommitLimit; systemPageReads=$m.PageReadsPersec
        }
    } catch {
        [pscustomobject]@{availableBytes=$null; committedBytes=$null; commitLimitBytes=$null; systemPageReads=$null}
    }
}
