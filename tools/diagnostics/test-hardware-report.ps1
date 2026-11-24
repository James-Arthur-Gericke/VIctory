$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'HardwareReportMetrics.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$start=Get-Utc '2026-01-01T00:00:00Z';$end=$start.AddSeconds(4)
Assert ((Get-Metric @(1,$null,3) 'x').value -eq 2) 'Null not zero.'
Assert ($null -eq (Get-Metric @($null) 'x').value) 'Missing metric.'
Assert ((Get-Metric @(1,3) 'x' -Peak).value -eq 3) 'Peak.'
$rows=@([pscustomobject]@{schema='s';utc=$start.ToString('o');processId=1;processStartUtcTicks=2},
    [pscustomobject]@{schema='s';utc=$start.AddSeconds(2).ToString('o');processId=1;processStartUtcTicks=2})
$s=@(Select-Telemetry $rows 's' $start $end 1 2)
Assert ((Get-NearestSample $s $start.AddMilliseconds(1900) 200).at -eq $start.AddSeconds(2)) 'Nearest.'
Assert ($null -eq (Get-NearestSample $s $start.AddSeconds(1) 100)) 'Gap.'
$failed=$false;try {Select-Telemetry $rows 's' $start $end 2 2 | Out-Null}catch{$failed=$true}
Assert $failed 'Reject mixed PID.'
$events=@(Read-VictoryFrames @('2026-01-01T00:00:01Z INFO victory_gpu::host: 10.0 fps, 100.0 ms/frame (20.0 preparing: copies 1.0 ms 1.0 MB, textures 2.0 ms 2.0 MB; 70.0 on the GPU; 10.0 copying back 2.0 MB), 20 draws/frame, dropped 2 without a host pipeline (0 being made) and 0 indirect sample_frames=10',
'2026-01-01T00:00:02Z INFO victory_gpu::host: GPU memory budget sample node=0 segment="local" usage_bytes=100 budget_bytes=200') $start $end)
Assert ($events.Count -eq 2 -and $events[0].cpuMs -eq 20 -and $events[1].usage -eq 100) 'Log parser.'
Assert ((Get-FrameMetric @($events[0]) 'cpuMs' 'ms/frame').value -eq 20) 'Weighted frame.'
$dir=Join-Path ([IO.Path]::GetTempPath()) ('victory-report-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $manifest=[pscustomobject]@{schema='victory.hardware.manifest.v1';runId='fixture';buildSha=('a'*40);conditionsKey='synthetic';processId=1;processStartUtcTicks=2;windowStartUtc=$start.ToString('o');windowEndUtc=$end.ToString('o');visualCorrect=$true;deviceRemoved=$false;windowAligned=$true}
    $p=Join-Path $dir 'manifest.json';$manifest | ConvertTo-Json | Set-Content -LiteralPath $p
    $report=& (Join-Path $PSScriptRoot 'New-HardwareReport.ps1') -Manifest $p | ConvertFrom-Json
    Assert ($report.schema -eq 'victory.hardware.report.v1' -and $null -eq $report.metrics.presentFps.value -and $report.counts.cpu -eq 0) 'Missing sources smoke.'
}finally{Remove-Item -LiteralPath $dir -Recurse -Force}
Write-Host 'Hardware report tests passed.'
