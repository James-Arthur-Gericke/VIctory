# Read-only process and system memory samples; JSON lines to stdout.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId,
      [ValidateRange(2,3600)][int]$Samples=60,
      [ValidateRange(250,10000)][int]$IntervalMs=1000)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RamMetrics.ps1')
if (-not $IsWindows) { throw 'Windows PowerShell 7+ required.' }
$p=[Diagnostics.Process]::GetProcessById($ProcessId)
try {
    $identity=$p.StartTime.ToUniversalTime().Ticks
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $prev=$null; $peakPrivate=[long]0; $peakWorking=[long]0
    for ($i=0; $i -lt $Samples; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds $IntervalMs }
        $p.Refresh()
        if ($p.HasExited -or $p.StartTime.ToUniversalTime().Ticks -ne $identity) { break }
        $at=$clock.Elapsed.TotalMilliseconds
        $private=$p.PrivateMemorySize64; $working=$p.WorkingSet64
        $peakPrivate=[Math]::Max($peakPrivate,$private); $peakWorking=[Math]::Max($peakWorking,$working)
        $system=Get-SystemRamSnapshot
        [pscustomobject]@{
            schema='victory.ram.sample.v1'; utc=[DateTime]::UtcNow.ToString('o'); elapsedMs=$at
            processId=$ProcessId; processStartUtcTicks=$identity
            privateBytes=$private; workingSetBytes=$working; peakSamplePrivateBytes=$peakPrivate; peakSampleWorkingSetBytes=$peakWorking
            systemAvailableBytes=$system.availableBytes; systemCommittedBytes=$system.committedBytes
            systemCommitLimitBytes=$system.commitLimitBytes
            systemPageReadDelta=Get-MemoryDelta $prev $system.systemPageReads
            processHardFaults=$null; retainedStagingBytes=$null
        } | ConvertTo-Json -Compress
        $prev=$system.systemPageReads
    }
} finally { $p.Dispose() }
