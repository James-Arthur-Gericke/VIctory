$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../diagnostics/StorageMetrics.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
Assert ((Get-IoRate 10 110 2) -eq 50) 'Byte rate.'
Assert ($null -eq (Get-IoRate 100 90 1)) 'Reset.'
Assert ($null -eq (Get-IoRate $null 90 1)) 'Missing.'
Assert ($null -eq (Get-IoRate 10 90 0)) 'Zero interval.'
$a=[pscustomobject]@{AvgDisksecPerRead=100;AvgDisksecPerRead_Base=10;Frequency_PerfTime=1000}
$b=[pscustomobject]@{AvgDisksecPerRead=140;AvgDisksecPerRead_Base=14;Frequency_PerfTime=1000}
Assert ((Get-DiskLatencyMs $a $b 'Read') -eq 10) 'Average timer.'
$b.AvgDisksecPerRead_Base=10
Assert ($null -eq (Get-DiskLatencyMs $a $b 'Read')) 'No completed ops.'
$b.AvgDisksecPerRead_Base=14; $b.Frequency_PerfTime=2000
Assert ($null -eq (Get-DiskLatencyMs $a $b 'Read')) 'Changed frequency.'
$indices=@(0..63 | ForEach-Object {Get-ReadBlockIndex $_ 64 $true} | Sort-Object -Unique)
Assert ($indices.Count -eq 64 -and $indices[0] -eq 0 -and $indices[-1] -eq 63) 'Permutation covers each block.'
$rows=@(& (Join-Path $PSScriptRoot '../diagnostics/Collect-Storage.ps1') -ProcessId $PID -Samples 2 -IntervalMs 250 | ForEach-Object {$_ | ConvertFrom-Json})
Assert ($rows.Count -eq 2 -and $null -ne $rows[1].processIo -and $null -ne $rows[1].processRates) 'Live process I/O smoke.'
$dir=Join-Path ([IO.Path]::GetTempPath()) ("victory-storage-test-"+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $samples=@(& (Join-Path $PSScriptRoot 'Test-StorageReads.ps1') -Directory $dir -SizeMiB 8 -Repeats 1 | ForEach-Object {$_ | ConvertFrom-Json})
    Assert ($samples.Count -eq 4 -and $samples[0].bytes -eq 8MB -and $samples[0].bytesPerSecond -gt 0) 'Synthetic fixture smoke.'
    Assert (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) 'Fixture cleanup.'
} finally { Remove-Item -LiteralPath $dir -Recurse -Force }
Write-Host 'Storage profiling tests passed.'
