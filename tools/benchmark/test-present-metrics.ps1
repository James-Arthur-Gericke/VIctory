$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PresentMetrics.ps1')

function Assert-Near([double]$Actual, [double]$Expected) {
    if ([Math]::Abs($Actual - $Expected) -gt 0.000001) {
        throw "Expected $Expected, got $Actual"
    }
}
function Assert-Rejected([scriptblock]$Work) {
    $rejected = $false
    try { & $Work | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Expected rejection.' }
}

$rows = @(
    'ProcessID,SwapChainAddress,MsBetweenPresents'
    '10,0xAB,0'
    '20,0xAB,999'
    '10,0xFF,999'
    '10,0xAB,10'
    '10,0xAB,20'
    '10,0xAB,30'
    '10,0xAB,40'
) | ConvertFrom-Csv
$m = Measure-PresentRows -Rows $rows -ProcessId 10 -SwapChain '0xAB'
Assert-Near $m.Intervals 4
Assert-Near $m.DurationSeconds 0.1
Assert-Near $m.PresentFPS 40
Assert-Near $m.MeanMs 25
Assert-Near $m.P50Ms 20
Assert-Near $m.P95Ms 40
Assert-Near $m.P99Ms 40
Assert-Near $m.MaxMs 40
$window = Measure-PresentRows -Rows $rows -ProcessId 10 -SwapChain '0xAB' -Skip 2 -Count 2
Assert-Near $window.MeanMs 25
Assert-Near $window.Intervals 2
Assert-Rejected { Measure-PresentRows -Rows $rows -ProcessId 10 -SwapChain '0xAB' -Count 5 }
Assert-Rejected { Measure-PresentRows -Rows $rows -ProcessId 99 -SwapChain '0xAB' }
Assert-Rejected { Measure-PresentRows -Rows @([pscustomobject]@{ Other = 1 }) -ProcessId 10 -SwapChain '0xAB' }

foreach ($invalid in @('NA', 'NaN', 'Infinity', '-1', '0', '1,25')) {
    $bad = @(
        'ProcessID,SwapChainAddress,MsBetweenPresents'
        '10,0xAB,0'
        ('10,0xAB,"' + $invalid + '"')
    ) | ConvertFrom-Csv
    Assert-Rejected { Measure-PresentRows -Rows $bad -ProcessId 10 -SwapChain '0xAB' }
}

# Percentiles are nearest-rank, and FPS uses total elapsed intervals.
$tail = @('ProcessID,SwapChainAddress,MsBetweenPresents', '10,0xAB,0')
$tail += @(1..99 | ForEach-Object { '10,0xAB,10' })
$tail += '10,0xAB,1000'
$t = Measure-PresentRows -Rows @($tail | ConvertFrom-Csv) -ProcessId 10 -SwapChain '0xAB'
Assert-Near $t.P99Ms 10
Assert-Near $t.MaxMs 1000
Assert-Near $t.PresentFPS (100000.0 / 1990.0)
Write-Host 'PresentMon interval tests passed.'
