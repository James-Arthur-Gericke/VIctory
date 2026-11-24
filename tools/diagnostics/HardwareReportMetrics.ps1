Set-StrictMode -Version Latest
function Get-Field($Object,[string]$Name) {
    if ($null -eq $Object) { return $null }
    $p=$Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}
function Get-Utc($Value) {
    if ($Value -is [datetime]) { return [DateTimeOffset]$Value }
    if ($null -eq $Value -or [string]$Value -notmatch '(Z|[+-]\d\d:\d\d)$') { throw 'Explicit offset timestamp required.' }
    [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}
function Get-Number($Value) {
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    $v=0.0
    if (-not [double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$v) -or
        -not [double]::IsFinite($v) -or $v -lt 0) { return $null }
    return $v
}
function Get-Metric($Values,[string]$Unit,[switch]$Peak) {
    $valid=@(foreach ($v in $Values) { $n=Get-Number $v; if ($null -ne $n) { $n } })
    $value=$null
    if ($valid.Count -gt 0) {
        $m=$valid | Measure-Object -Average -Maximum
        $value=if($Peak){$m.Maximum}else{$m.Average}
    }
    [pscustomobject]@{value=$value;unit=$Unit;samples=$valid.Count}
}
function Select-Telemetry($Rows,[string]$Schema,$Start,$End,$ProcessId,$StartTicks) {
    $previous=$null
    foreach ($row in $Rows) {
        if ($row.schema -ne $Schema) { throw 'Unexpected telemetry schema.' }
        if ($null -ne $ProcessId -and ($row.processId -ne $ProcessId -or $row.processStartUtcTicks -ne $StartTicks)) { throw 'Mixed process telemetry.' }
        $at=Get-Utc $row.utc
        if ($null -ne $previous -and $at -le $previous) { throw 'Telemetry time must strictly increase.' }
        $previous=$at
        if ($at -ge $Start -and $at -le $End) {
            [pscustomobject]@{at=$at;row=$row}
        }
    }
}
function Get-NearestSample($Samples,$At,[double]$MaxSkewMs) {
    $best=$null; $distance=[double]::PositiveInfinity
    foreach ($s in $Samples) {
        $d=[Math]::Abs(($s.at-$At).TotalMilliseconds)
        if ($d -lt $distance) { $distance=$d; $best=$s }
    }
    if ($distance -le $MaxSkewMs) { return $best }
    return $null
}
function Read-VictoryFrames($Lines,$Start,$End) {
    $pattern='(?<fps>\d+(\.\d+)?) fps, (?<ms>\d+(\.\d+)?) ms/frame \((?<cpu>\d+(\.\d+)?) preparing:.*?; (?<gpu>\d+(\.\d+)?) on the GPU;.*? (?<draws>\d+(\.\d+)?) draws/frame, dropped (?<drops>\d+(\.\d+)?) without a host pipeline'
    foreach ($raw in $Lines) {
        $line=$raw -replace '\x1b\[[0-?]*[ -/]*[@-~]',''
        if ($line -notmatch '^(?<stamp>\d{4}-\d{2}-\d{2}T\S+)\s') { continue }
        $at=Get-Utc $Matches.stamp
        if ($at -lt $Start -or $at -gt $End) { continue }
        $m=[regex]::Match($line,$pattern)
        if ($m.Success) {
            $count=[regex]::Match($line,'\bsample_frames=(\d+)')
            [pscustomobject]@{at=$at;kind='frame';frames=if($count.Success){[int64]$count.Groups[1].Value}else{$null}
                frameMs=Get-Number $m.Groups['ms'].Value;cpuMs=Get-Number $m.Groups['cpu'].Value
                gpuMs=Get-Number $m.Groups['gpu'].Value;dropped=Get-Number $m.Groups['drops'].Value}
        } elseif ($line -match 'GPU memory budget sample' -and $line -match '\bsegment="?local"?(?:\s|$)') {
            $usage=[regex]::Match($line,'\busage_bytes=(\d+)')
            $budget=[regex]::Match($line,'\bbudget_bytes=(\d+)')
            if ($usage.Success -and $budget.Success) {
                [pscustomobject]@{at=$at;kind='gpu';usage=Get-Number $usage.Groups[1].Value;budget=Get-Number $budget.Groups[1].Value}
            }
        } elseif ($line -match 'shader compilation profile \(inclusive worker elapsed time\)') {
            $phase=[regex]::Match($line,'\bphase="?([a-z-]+)"?')
            $calls=[regex]::Match($line,'\bcalls=(\d+)')
            $us=[regex]::Match($line,'\btotal_us=(\d+)')
            if ($phase.Success -and $calls.Success -and $us.Success -and $phase.Groups[1].Value -eq 'translate') {
                [pscustomobject]@{at=$at;kind='shader';calls=Get-Number $calls.Groups[1].Value;totalUs=Get-Number $us.Groups[1].Value}
            }
        }
    }
}
function Get-FrameMetric($Frames,[string]$Field,[string]$Unit) {
    $sum=0.0; $weight=0.0; $count=0
    foreach($f in $Frames) {
        $n=Get-Number (Get-Field $f $Field); $w=Get-Number $f.frames
        if ($null -eq $n -or $null -eq $w -or $w -le 0) {
            return [pscustomobject]@{value=$null;unit=$Unit;samples=0}
        }
        $sum+=$n*$w; $weight+=$w; $count++
    }
    [pscustomobject]@{value=if($weight -gt 0){$sum/$weight}else{$null};unit=$Unit;samples=$count}
}
