$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$dir=Join-Path ([IO.Path]::GetTempPath()) ('victory-integration-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $pairs=@()
    foreach($n in 1..3) {
        $sides=@{}
        foreach($side in @('baseline','candidate')) {
            $id="$side-$n"
            $sha=if($side -eq 'baseline'){'a'*40}else{'b'*40}
            $pidValue=1000+$n*2+$(if($side -eq 'baseline'){0}else{1})
            $start=[DateTimeOffset]::Parse('2026-01-01T00:00:00Z').AddMinutes($pidValue)
            $ticks=[long]12345+$pidValue
            $cpu=@();$ram=@();$storage=@();$log=@()
            foreach($i in 1..3) {
                $utc=$start.AddSeconds($i).ToString('o')
                $cpu+=([pscustomobject]@{schema='victory.cpu.sample.v1';utc=$utc;processId=$pidValue;processStartUtcTicks=$ticks;cpuPercentMachine=20}|ConvertTo-Json -Compress)
                $ram+=([pscustomobject]@{schema='victory.ram.sample.v1';utc=$utc;processId=$pidValue;processStartUtcTicks=$ticks;privateBytes=100000;workingSetBytes=80000}|ConvertTo-Json -Compress)
                $storage+=([pscustomobject]@{schema='victory.storage.sample.v1';utc=$utc;processId=$pidValue;processStartUtcTicks=$ticks;processRates=@{readBytesPerSecond=500};physicalDisks=@(@{instance='disk';meanReadLatencyMs=1;readBytesPerSecond=500;currentQueueLength=1})}|ConvertTo-Json -Depth 5 -Compress)
                $log+="$utc INFO victory_gpu::host: 100.0 fps, 10.0 ms/frame (2.0 preparing: copies 1.0 ms 1.0 MB, textures 1.0 ms 1.0 MB; 7.0 on the GPU; 1.0 copying back 1.0 MB), 20 draws/frame, dropped 0 without a host pipeline (0 being made) and 0 indirect sample_frames=10"
            }
            $cpu|Set-Content -LiteralPath (Join-Path $dir "$id-cpu.jsonl")
            $ram|Set-Content -LiteralPath (Join-Path $dir "$id-ram.jsonl")
            $storage|Set-Content -LiteralPath (Join-Path $dir "$id-storage.jsonl")
            $log|Set-Content -LiteralPath (Join-Path $dir "$id.log")
            $csv=@('ProcessID,SwapChainAddress,MsBetweenPresents')+@(1..1001|ForEach-Object{"$pidValue,0xAB,10"})
            $csv|Set-Content -LiteralPath (Join-Path $dir "$id.csv")
            $manifest=@{schema='victory.hardware.manifest.v1';runId=$id;buildSha=$sha;conditionsKey='synthetic';processId=$pidValue;processStartUtcTicks=$ticks
                windowStartUtc=$start.ToString('o');windowEndUtc=$start.AddSeconds(10).ToString('o');windowAligned=$true;visualCorrect=$true;deviceRemoved=$false
                cpu="$id-cpu.jsonl";ram="$id-ram.jsonl";storage="$id-storage.jsonl";diskInstance='disk';victoryLog="$id.log";presentCsv="$id.csv";present=@{swapChain='0xAB';skip=1;count=1000}}
            $m=Join-Path $dir "$id-manifest.json"
            $manifest|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $m
            $report=& (Join-Path $PSScriptRoot '../diagnostics/New-HardwareReport.ps1') -Manifest $m
            $obj=$report|ConvertFrom-Json
            if($obj.metrics.presentFps.value -ne 100 -or $obj.metrics.ramPrivatePeakBytes.value -ne 100000 -or $obj.metrics.diskReadLatencyMs.value -ne 1 -or $obj.metrics.droppedDrawsPerFrame.value -ne 0 -or $obj.metrics.gpuBusyPercent.samples -ne 0){throw 'Integrated report mismatch.'}
            $report|Set-Content -LiteralPath (Join-Path $dir "$id-report.json")
            $sides[$side]=@{report="$id-report.json"}
        }
        $pairs+=$sides
    }
    $gate=Join-Path $dir 'gate.json'
    @{schema='victory.hardware.regression.manifest.v1';comparable=$true;thresholds=@{ramPrivatePeakBytes=10;diskReadLatencyMs=10;cpuPrepareMs=10};pairs=$pairs}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $gate
    $result=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-HardwareRegression.ps1') -Manifest $gate
    if($LASTEXITCODE -ne 0 -or -not ($result|ConvertFrom-Json).passed){throw 'Integrated regression gate failed.'}
} finally {Remove-Item -LiteralPath $dir -Recurse -Force}
Write-Host 'Combined report-to-regression integration smoke passed.'
exit 0
