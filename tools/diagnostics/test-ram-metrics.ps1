$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RamMetrics.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
Assert ((Get-RamTrend @(100,110,120,140) 30).status -eq 'candidate-growth') 'Rising checkpoints.'
Assert ((Get-RamTrend @(100,100,100,100) 1).status -eq 'no-sustained-growth') 'Stable.'
Assert ((Get-RamTrend @(100,150,120,180) 1).status -eq 'no-sustained-growth') 'Nonmonotonic.'
Assert ((Get-RamTrend @(100,110,120,130) 40).status -eq 'no-sustained-growth') 'Threshold.'
Assert ((Get-RamTrend @(100,110,120) 1).status -eq 'insufficient-data') 'Too few cycles.'
Assert ((Get-RamTrend @(100,$null,120,130) 1).status -eq 'insufficient-data') 'Missing.'
Assert ($null -eq (Get-MemoryDelta 10 9)) 'Reset.'
Assert ($null -eq (Get-MemoryDelta $null 9)) 'Missing previous.'
Assert ((Get-MemoryDelta 10 15) -eq 5) 'Delta.'
$rows=@(& (Join-Path $PSScriptRoot 'Collect-Ram.ps1') -ProcessId $PID -Samples 2 -IntervalMs 250 | ForEach-Object {$_ | ConvertFrom-Json})
Assert ($rows.Count -eq 2 -and $rows[1].privateBytes -gt 0 -and $rows[1].workingSetBytes -gt 0) 'Live process smoke.'
Assert ($rows[1].peakSamplePrivateBytes -ge $rows[1].privateBytes) 'Peak.'
Assert ($null -eq $rows[0].systemPageReadDelta) 'First counter delta absent.'
Write-Host 'RAM telemetry tests passed.'
