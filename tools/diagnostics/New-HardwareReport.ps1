# Combine existing local capture files; no title execution or sensor inference.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Manifest,[switch]$HumanReadable,
      [ValidateRange(0,10000)][int]$MaxSkewMs=1500)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'HardwareReportMetrics.ps1')
. (Join-Path $PSScriptRoot '../benchmark/PresentMetrics.ps1')
$path=(Resolve-Path -LiteralPath $Manifest).ProviderPath
$root=Split-Path -Parent $path
$spec=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
function Resolve-Capture($Name) {
    $p=Get-Field $spec $Name
    if (-not $p) { return $null }
    if (-not [IO.Path]::IsPathRooted($p)) {$p=Join-Path $root $p}
    (Resolve-Path -LiteralPath $p).ProviderPath
}
function Read-Samples($Name,$Schema,$PidValue,$Ticks) {
    $p=Resolve-Capture $Name
    if (-not $p) { return }
    $rows=@(Get-Content -LiteralPath $p | ForEach-Object {$_ | ConvertFrom-Json})
    Select-Telemetry $rows $Schema $start $end $PidValue $Ticks
}
if ($spec.schema -ne 'victory.hardware.manifest.v1' -or $spec.windowAligned -isnot [bool] -or -not $spec.windowAligned) { throw 'Confirm captures cover the selected window.' }
foreach($key in @('runId','buildSha','conditionsKey','processId','processStartUtcTicks','windowStartUtc','windowEndUtc','visualCorrect','deviceRemoved')) {
    if ($null -eq (Get-Field $spec $key)) { throw "Missing manifest field: $key" }
}
if ($spec.buildSha -notmatch '^[0-9a-fA-F]{40}$' -or $spec.processId -le 0 -or $spec.processStartUtcTicks -le 0 -or
    [string]::IsNullOrWhiteSpace($spec.runId) -or [string]::IsNullOrWhiteSpace($spec.conditionsKey) -or
    $spec.visualCorrect -isnot [bool] -or $spec.deviceRemoved -isnot [bool]) { throw 'Invalid manifest identity or correctness flags.' }
$start=Get-Utc $spec.windowStartUtc; $end=Get-Utc $spec.windowEndUtc
if ($end -le $start) { throw 'Invalid capture window.' }
$cpu=@(Read-Samples 'cpu' 'victory.cpu.sample.v1' $spec.processId $spec.processStartUtcTicks)
$ram=@(Read-Samples 'ram' 'victory.ram.sample.v1' $spec.processId $spec.processStartUtcTicks)
$storage=@(Read-Samples 'storage' 'victory.storage.sample.v1' $spec.processId $spec.processStartUtcTicks)
$vendor=@(Read-Samples 'gpu' 'victory.gpu.external.v1' $null $null)
$adapter=Get-Field $spec 'gpuAdapter'
if ($vendor.Count -gt 0 -and (-not $adapter -or @($vendor | Where-Object {$_.row.adapter -ne $adapter}).Count -gt 0)) { throw 'GPU adapter mismatch.' }
$log=Resolve-Capture 'victoryLog'
$events=if($log){@(Read-VictoryFrames (Get-Content -LiteralPath $log) $start $end)}else{@()}
$frames=@($events | Where-Object kind -eq 'frame')
$budget=@($events | Where-Object kind -eq 'gpu')
$shader=@($events | Where-Object kind -eq 'shader')
$diskName=Get-Field $spec 'diskInstance'
$diskRows=@(foreach($s in $storage){ foreach($d in @(Get-Field $s.row 'physicalDisks')) { if($null -ne $d -and $diskName -and $d.instance -eq $diskName){$d} }})
$metrics=[ordered]@{
    cpuMachinePercent=Get-Metric @($cpu | ForEach-Object {Get-Field $_.row 'cpuPercentMachine'}) 'percent'
    ramPrivatePeakBytes=Get-Metric @($ram | ForEach-Object {$_.row.privateBytes}) 'bytes' -Peak
    ramWorkingSetPeakBytes=Get-Metric @($ram | ForEach-Object {$_.row.workingSetBytes}) 'bytes' -Peak
    gpuBusyPercent=Get-Metric @($vendor | ForEach-Object {Get-Field $_.row 'busyPercent'}) 'percent'
    gpuClockMHz=Get-Metric @($vendor | ForEach-Object {Get-Field $_.row 'clockMHz'}) 'MHz'
    gpuTemperatureC=Get-Metric @($vendor | ForEach-Object {Get-Field $_.row 'temperatureC'}) 'C'
    gpuPowerW=Get-Metric @($vendor | ForEach-Object {Get-Field $_.row 'powerW'}) 'W'
    gpuLocalUsagePeakBytes=Get-Metric @($budget | ForEach-Object {$_.usage}) 'bytes' -Peak
    gpuLocalBudgetBytes=Get-Metric @($budget | ForEach-Object {$_.budget}) 'bytes'
    processReadBytesPerSecond=Get-Metric @($storage | ForEach-Object {Get-Field (Get-Field $_.row 'processRates') 'readBytesPerSecond'}) 'bytes/s'
    diskReadLatencyMs=Get-Metric @($diskRows | ForEach-Object {Get-Field $_ 'meanReadLatencyMs'}) 'ms'
    diskReadBytesPerSecond=Get-Metric @($diskRows | ForEach-Object {Get-Field $_ 'readBytesPerSecond'}) 'bytes/s'
    diskQueueLength=Get-Metric @($diskRows | ForEach-Object {Get-Field $_ 'currentQueueLength'}) 'requests'
    cpuPrepareMs=Get-FrameMetric $frames 'cpuMs' 'ms/frame'
    gpuWaitMs=Get-FrameMetric $frames 'gpuMs' 'ms/frame'
    droppedDrawsPerFrame=Get-FrameMetric $frames 'dropped' 'draws/frame'
}
$calls=0.0;$us=0.0
foreach($s in $shader){$calls+=$s.calls;$us+=$s.totalUs}
$metrics.shaderTranslateMeanMs=[pscustomobject]@{value=if($calls -gt 0){$us/$calls/1000}else{$null};unit='ms/call';samples=$shader.Count}
$present=Get-Field $spec 'present'
$presentPath=Resolve-Capture 'presentCsv'
if ($presentPath) {
    if ($null -eq $present) { throw 'Missing PresentMon window selection.' }
    $pm=Measure-PresentRows -Rows @(Import-Csv -LiteralPath $presentPath) -ProcessId $spec.processId -SwapChain $present.swapChain -Skip $present.skip -Count $present.count
    if ([Math]::Abs($pm.DurationSeconds/($end-$start).TotalSeconds-1) -gt 0.1) { throw 'Present window duration differs by over 10%.' }
    foreach($pair in @(@('presentFps','PresentFPS','fps'),@('presentP95Ms','P95Ms','ms'),@('presentP99Ms','P99Ms','ms'))) {
        $metrics[$pair[0]]=[pscustomobject]@{value=$pm.($pair[1]);unit=$pair[2];samples=$pm.Intervals}
    }
} else {
    foreach($pair in @(@('presentFps','fps'),@('presentP95Ms','ms'),@('presentP99Ms','ms'))) {
        $metrics[$pair[0]]=[pscustomobject]@{value=$null;unit=$pair[1];samples=0}
    }
}
# CPU timestamps are alignment anchors. No interpolation or extrapolation.
$aligned=@(foreach($c in $cpu) {
    $rr=Get-NearestSample $ram $c.at $MaxSkewMs
    $ss=Get-NearestSample $storage $c.at $MaxSkewMs
    $gg=Get-NearestSample $vendor $c.at $MaxSkewMs
    [pscustomobject]@{utc=$c.at.ToString('o');elapsedMs=($c.at-$start).TotalMilliseconds
        cpuMachinePercent=Get-Field $c.row 'cpuPercentMachine'
        ramPrivateBytes=Get-Field (Get-Field $rr 'row') 'privateBytes'
        ramSkewMs=if($rr){($rr.at-$c.at).TotalMilliseconds}else{$null}
        processReadBytesPerSecond=Get-Field (Get-Field (Get-Field $ss 'row') 'processRates') 'readBytesPerSecond'
        storageSkewMs=if($ss){($ss.at-$c.at).TotalMilliseconds}else{$null}
        gpuBusyPercent=Get-Field (Get-Field $gg 'row') 'busyPercent'
        gpuSkewMs=if($gg){($gg.at-$c.at).TotalMilliseconds}else{$null}}
})
$result=[pscustomobject]@{
    schema='victory.hardware.report.v1';runId=$spec.runId;buildSha=$spec.buildSha;conditionsKey=$spec.conditionsKey
    windowStartUtc=$start.ToString('o');windowEndUtc=$end.ToString('o');durationSeconds=($end-$start).TotalSeconds
    visualCorrect=$spec.visualCorrect;deviceRemoved=$spec.deviceRemoved;windowAligned=$true
    diskInstance=$diskName;gpuAdapter=$adapter;maxSkewMs=$MaxSkewMs;metrics=$metrics
    counts=[pscustomobject]@{cpu=$cpu.Count;ram=$ram.Count;storage=$storage.Count;gpu=$vendor.Count;frames=$frames.Count;budget=$budget.Count;shader=$shader.Count}
    aligned=$aligned
}
if ($HumanReadable) {
    "Run: $($result.runId); duration: $($result.durationSeconds) s"
    foreach($key in $metrics.Keys){$m=$metrics[$key];if($null -eq $m.value){"$key : unavailable"}else{"$key : $($m.value) $($m.unit) ($($m.samples) samples)"}}
} else { $result | ConvertTo-Json -Depth 8 }
