# Read-only process and disk telemetry, JSON lines.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId,
      [ValidateRange(2,3600)][int]$Samples=30,[ValidateRange(250,10000)][int]$IntervalMs=1000)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StorageMetrics.ps1')
if (-not $IsWindows) { throw 'Windows PowerShell 7+ required.' }
$p=[Diagnostics.Process]::GetProcessById($ProcessId)
try {
    $identity=$p.StartTime.ToUniversalTime().Ticks
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $previous=$null; $previousAt=$null; $disks=@{}
    for ($i=0;$i -lt $Samples;$i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds $IntervalMs }
        $p.Refresh()
        if ($p.HasExited -or $p.StartTime.ToUniversalTime().Ticks -ne $identity) { break }
        $at=$clock.Elapsed.TotalMilliseconds
        $utc=[DateTime]::UtcNow.ToString('o')
        $dt=if ($null -ne $previousAt) { ($at-$previousAt)/1000.0 } else { $null }
        $io=Get-ProcessIo $p
        $rates=$null
        if ($null -ne $io -and $null -ne $previous) {
            $rates=[pscustomobject]@{
                readBytesPerSecond=Get-IoRate $previous.readBytes $io.readBytes $dt
                writeBytesPerSecond=Get-IoRate $previous.writeBytes $io.writeBytes $dt
                readOpsPerSecond=Get-IoRate $previous.readOps $io.readOps $dt
                writeOpsPerSecond=Get-IoRate $previous.writeOps $io.writeOps $dt
            }
        }
        $current=@{}; $rows=@()
        foreach ($d in @(Get-PhysicalDiskCounters)) {
            $old=$disks[$d.Name]; $current[$d.Name]=$d
            $diskDt=$null
            if ($null -ne $old -and $d.Frequency_PerfTime -gt 0 -and $old.Frequency_PerfTime -eq $d.Frequency_PerfTime) {
                $ticks=Get-IoDelta $old.Timestamp_PerfTime $d.Timestamp_PerfTime
                if ($null -ne $ticks) { $diskDt=$ticks/$d.Frequency_PerfTime }
            }
            $rows += [pscustomobject]@{
                instance=$d.Name; currentQueueLength=$d.CurrentDiskQueueLength
                readBytesPerSecond=if ($null -ne $old) { Get-IoRate $old.DiskReadBytesPersec $d.DiskReadBytesPersec $diskDt } else { $null }
                writeBytesPerSecond=if ($null -ne $old) { Get-IoRate $old.DiskWriteBytesPersec $d.DiskWriteBytesPersec $diskDt } else { $null }
                meanReadLatencyMs=Get-DiskLatencyMs $old $d 'Read'
                meanWriteLatencyMs=Get-DiskLatencyMs $old $d 'Write'
            }
        }
        [pscustomobject]@{
            schema='victory.storage.sample.v1'; utc=$utc; elapsedMs=$at; intervalSeconds=$dt
            processId=$ProcessId; processStartUtcTicks=$identity; processIo=$io; processRates=$rates
            physicalDisks=if ($rows.Count -gt 0) { $rows } else { $null }
        } | ConvertTo-Json -Depth 5 -Compress
        $previous=$io; $previousAt=$at; $disks=$current
    }
} finally { $p.Dispose() }
