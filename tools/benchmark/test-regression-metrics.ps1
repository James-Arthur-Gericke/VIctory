$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RegressionMetrics.ps1')

function Metric([double]$Fps, [double]$P95, [double]$P99, [double]$Seconds = 60, [int]$N = 1200) {
    [pscustomobject]@{ PresentFPS = $Fps; P95Ms = $P95; P99Ms = $P99; DurationSeconds = $Seconds; Intervals = $N }
}
function Pair($a, $b) { [pscustomobject]@{ Baseline = $a; Candidate = $b } }
function Reject([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected invalid input rejection.' }
}
$a = Metric 60 20 30
$good = Pair $a (Metric 61 19 29)
$slow = Pair $a (Metric 50 25 40)
$r = Test-PresentRegression -Pairs @($good, $good, $slow)
if (-not $r.Passed) { throw 'One outlier should not dominate median.' }
$r = Test-PresentRegression -Pairs @($slow, $good, $slow)
if ($r.Passed -or @($r.Metrics | Where-Object ExceedsLimit).Count -ne 3) { throw 'Expected three regressions.' }
$tail = Pair $a (Metric 60 20 40)
$r = Test-PresentRegression -Pairs @($tail, $tail, $good)
if ($r.Passed -or $r.Metrics[0].ExceedsLimit -or $r.Metrics[1].ExceedsLimit -or -not $r.Metrics[2].ExceedsLimit) { throw 'Expected P99-only failure.' }
Reject { Test-PresentRegression -Pairs @($good, $good) }
Reject { Test-PresentRegression -Pairs @($good, $good, (Pair $a (Metric 60 20 30 90))) }
Reject { Test-PresentRegression -Pairs @($good, $good, (Pair $a (Metric 60 20 30 60 99))) }
Reject { Test-PresentRegression -Pairs @($good, $good, (Pair $a (Metric 60 20 ([double]::NaN)))) }
$r = Test-PresentRegression -Pairs @($good, $good, $slow, $slow) -FpsLossPct 20 -P95RisePct 30 -P99RisePct 40
if (-not $r.Passed) { throw 'Custom thresholds should pass.' }
Write-Host 'Present regression gate tests passed.'
