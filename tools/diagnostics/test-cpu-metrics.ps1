$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'CpuMetrics.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
Assert ((Get-CpuDeltaPercent 100 350 100) -eq 250) 'Multicore CPU time must exceed 100% when appropriate.'
Assert ((Get-CpuDeltaPercent 100 100 100) -eq 0) 'Idle CPU delta.'
Assert ($null -eq (Get-CpuDeltaPercent 100 99 100)) 'Counter reset.'
Assert ($null -eq (Get-CpuDeltaPercent 100 110 0)) 'Zero interval.'
Assert ($null -eq (Get-CpuDeltaPercent $null 110 100)) 'Missing prior.'
Assert ($null -eq (Get-CpuDeltaPercent 0 ([double]::NaN) 100)) 'Invalid counter.'
$a = @{ startTicks = 1; cpuMs = 10 }
$b = @{ startTicks = 1; cpuMs = 20 }
Assert ((Get-ThreadCpuDelta $a $b 100) -eq 10) 'Matching thread delta.'
$b.startTicks = 2
Assert ($null -eq (Get-ThreadCpuDelta $a $b 100)) 'Reused thread ID.'
$b.startTicks = $null
Assert ($null -eq (Get-ThreadCpuDelta $a $b 100)) 'Unavailable thread identity.'
# Smoke the actual Windows collector on this test process, no game required.
$rows = @(& (Join-Path $PSScriptRoot 'Collect-Cpu.ps1') -ProcessId $PID -Samples 2 -IntervalMs 250 -MaxThreads 2 | ForEach-Object { $_ | ConvertFrom-Json })
Assert ($rows.Count -eq 2) 'Expected two rows.'
Assert ($rows[0].schema -eq 'victory.cpu.sample.v1') 'Schema.'
Assert ($rows[0].topology.logical -gt 0) 'Logical processors.'
Assert ($null -eq $rows[0].cpuPercentOneLogical) 'First sample has no delta.'
Assert ($rows[1].intervalMs -gt 0 -and $null -ne $rows[1].cpuPercentOneLogical) 'Second sample has a delta.'
Assert (@($rows[1].threads).Count -le 2) 'Bounded thread rows.'
Assert ($null -eq $rows[1].temperatureC) 'Unavailable sensor remains null.'
Write-Host 'CPU telemetry tests passed.'
