Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RegressionMetrics.ps1')

function Get-HardwareField($Object,[string]$Name) {
    if ($null -eq $Object) { return $null }
    $p=$Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}
function Get-FiniteMetric($Value) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { throw 'Metric missing or not numeric.' }
    $v=[double]$Value
    if (-not [double]::IsFinite($v) -or $v -lt 0) { throw 'Non-finite or negative metric.' }
    return $v
}

# Fixed metric definitions prevent direction/unit changes between runs.
# CPU utilization, disk throughput and GPU busy are diagnostic context;
# lower utilization or higher I/O is not inherently an improvement.
$HardwareMetricDefinitions=[ordered]@{
    presentFps=@{unit='fps';direction='lower';mode='relative';minimum=1000}
    presentP95Ms=@{unit='ms';direction='higher';mode='relative';minimum=1000}
    presentP99Ms=@{unit='ms';direction='higher';mode='relative';minimum=1000}
    cpuPrepareMs=@{unit='ms/frame';direction='higher';mode='relative';minimum=3}
    gpuWaitMs=@{unit='ms/frame';direction='higher';mode='relative';minimum=3}
    shaderTranslateMeanMs=@{unit='ms/call';direction='higher';mode='relative';minimum=3}
    ramPrivatePeakBytes=@{unit='bytes';direction='higher';mode='relative';minimum=3}
    ramWorkingSetPeakBytes=@{unit='bytes';direction='higher';mode='relative';minimum=3}
    gpuLocalUsagePeakBytes=@{unit='bytes';direction='higher';mode='relative';minimum=3}
    diskReadLatencyMs=@{unit='ms';direction='higher';mode='relative';minimum=3}
    droppedDrawsPerFrame=@{unit='draws/frame';direction='higher';mode='absolute';minimum=3}
    transferUploadMiBps=@{unit='MiB/s';direction='lower';mode='relative';minimum=3}
}

function Read-TransferMetric($Lines,[int]$RegionBytes,[bool]$Pooled,[string]$AdapterIdentity) {
    if ($RegionBytes -lt 512 -or $RegionBytes -gt 16MB -or $RegionBytes%512 -ne 0) { throw 'Invalid transfer region size.' }
    $seen=[Collections.Generic.HashSet[int]]::new()
    $rates=@()
    foreach($line in $Lines) {
        if ($line -notmatch '^transfer-v1 ') { continue }
        $kv=@{}
        foreach($m in [regex]::Matches($line,'\b([a-z_]+)=([^\s]+)')) {
            if ($kv.ContainsKey($m.Groups[1].Value)) { throw 'Duplicate transfer field.' }
            $kv[$m.Groups[1].Value]=$m.Groups[2].Value
        }
        if ($kv.region_bytes -ne [string]$RegionBytes -or $kv.pooled -ne $Pooled.ToString().ToLowerInvariant()) { continue }
        if ($kv.adapter -ne 'hardware' -or $kv.verified -ne 'true' -or "$($kv.vendor):$($kv.device):$($kv.luid)" -ne $AdapterIdentity) {
            throw 'Transfer requires the same verified physical adapter.'
        }
        $repeat=[int]$kv.repeat
        if ($repeat -lt 1 -or -not $seen.Add($repeat) -or [long]$kv.bytes -ne 4L*$RegionBytes) { throw 'Invalid or repeated transfer sample.' }
        $ms=0.0
        if (-not [double]::TryParse($kv.upload_fence_ms,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$ms) -or
            -not [double]::IsFinite($ms) -or $ms -le 0) { throw 'Invalid upload duration.' }
        $rates+=([long]$kv.bytes/1MB)/($ms/1000.0)
    }
    [pscustomobject]@{value=if($rates.Count){Get-MedianValue $rates}else{$null};unit='MiB/s';samples=$rates.Count}
}

function Test-HardwareRegression($Pairs,$Thresholds,[double]$DurationTolerancePct=10) {
    if (@($Pairs).Count -lt 3) { throw 'At least three independent paired runs required.' }
    if (-not [double]::IsFinite($DurationTolerancePct) -or $DurationTolerancePct -lt 0 -or $DurationTolerancePct -gt 100) { throw 'Invalid duration tolerance.' }
    $limits=[ordered]@{presentFps=5;presentP95Ms=10;presentP99Ms=15;droppedDrawsPerFrame=0}
    foreach($p in $Thresholds.PSObject.Properties) {
        if (-not $HardwareMetricDefinitions.Contains($p.Name)) { throw "Unknown metric: $($p.Name)" }
        $limits[$p.Name]=Get-FiniteMetric $p.Value
    }
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $conditions=$null;$baseSha=$null;$candidateSha=$null
    $disk=$null;$adapter=$null;$skew=$null;$initialized=$false
    $correctnessFailures=0
    foreach($pair in $Pairs) {
        $a=$pair.baseline;$b=$pair.candidate
        foreach($run in @($a,$b)) {
            if ($run.schema -ne 'victory.hardware.report.v1' -or $run.windowAligned -isnot [bool] -or -not $run.windowAligned -or
                $run.visualCorrect -isnot [bool] -or $run.deviceRemoved -isnot [bool] -or
                [string]::IsNullOrWhiteSpace($run.runId) -or [string]::IsNullOrWhiteSpace($run.conditionsKey) -or
                $run.buildSha -notmatch '^[0-9a-fA-F]{40}$' -or -not $ids.Add([string]$run.runId)) { throw 'Invalid or reused run identity.' }
            if (-not $run.visualCorrect -or $run.deviceRemoved) { $correctnessFailures++ }
            $d=Get-FiniteMetric $run.durationSeconds
            if ($d -le 0) { throw 'Invalid run duration.' }
            if (-not $initialized) {
                $conditions=$run.conditionsKey;$disk=Get-HardwareField $run 'diskInstance';$adapter=Get-HardwareField $run 'gpuAdapter';$skew=Get-HardwareField $run 'maxSkewMs';$initialized=$true
            }
            if ($run.conditionsKey -cne $conditions -or (Get-HardwareField $run 'diskInstance') -cne $disk -or
                (Get-HardwareField $run 'gpuAdapter') -cne $adapter -or (Get-HardwareField $run 'maxSkewMs') -ne $skew) { throw 'Unmatched capture conditions.' }
        }
        if ($null -eq $baseSha) {$baseSha=$a.buildSha;$candidateSha=$b.buildSha}
        if ($a.buildSha -ne $baseSha -or $b.buildSha -ne $candidateSha -or $baseSha -eq $candidateSha) { throw 'Mixed or identical build identities.' }
        if (100*[Math]::Abs($b.durationSeconds/$a.durationSeconds-1) -gt $DurationTolerancePct) { throw 'Paired durations differ beyond tolerance.' }
    }
    if ($correctnessFailures -gt 0) {
        return [pscustomobject]@{schema='victory.hardware.regression.v1';passed=$false;status='correctness-failed';pairs=@($Pairs).Count;correctnessFailures=$correctnessFailures;metrics=@()}
    }
    $report=@()
    foreach($name in $limits.Keys) {
        $def=$HardwareMetricDefinitions[$name];$changes=@()
        foreach($pair in $Pairs) {
            $vals=@()
            foreach($run in @($pair.baseline,$pair.candidate)) {
                $m=Get-HardwareField $run.metrics $name
                if ($null -eq $m -or $m.unit -cne $def.unit -or (Get-FiniteMetric $m.samples) -lt $def.minimum -or
                    [Math]::Floor([double]$m.samples) -ne [double]$m.samples) { throw "Insufficient samples or wrong unit: $name" }
                $vals+=Get-FiniteMetric $m.value
            }
            $a=$vals[0];$b=$vals[1]
            if ($def.mode -eq 'relative') {
                if ($a -le 0) { throw "Zero relative baseline: $name" }
                $delta=100*($b/$a-1)
            } else { $delta=$b-$a }
            if ($def.direction -eq 'lower') {$delta=-$delta}
            if (-not [double]::IsFinite($delta)) {throw "Invalid change: $name"}
            # Any dropped draw increase is a correctness-related gate, not
            # something a median can hide. Optional positive threshold is explicit.
            $changes+=$delta
        }
        $median=Get-MedianValue $changes
        $score=if($name -eq 'droppedDrawsPerFrame'){($changes | Measure-Object -Maximum).Maximum}else{$median}
        $report+=[pscustomobject]@{metric=$name;mode=$def.mode;medianRegression=$median;gateScore=$score;limit=$limits[$name];exceedsLimit=($score -gt $limits[$name]);pairedChanges=$changes}
    }
    $passed=-not ($report.exceedsLimit -contains $true)
    [pscustomobject]@{schema='victory.hardware.regression.v1';passed=$passed;status=if($passed){'within-limits'}else{'regression'};pairs=@($Pairs).Count;correctnessFailures=0;metrics=$report}
}
