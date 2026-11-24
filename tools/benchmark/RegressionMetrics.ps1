# Deterministic regression scoring for repeated, already selected present intervals.
Set-StrictMode -Version Latest

function Get-MedianValue {
    param([double[]]$Values)
    $copy = [double[]]$Values.Clone()
    [Array]::Sort($copy)
    $mid = [int][Math]::Floor($copy.Length / 2)
    if ($copy.Length % 2 -eq 1) { return $copy[$mid] }
    return ($copy[$mid - 1] / 2) + ($copy[$mid] / 2)
}

function Test-PresentRegression {
    param(
        [Parameter(Mandatory)][object[]]$Pairs,
        [ValidateRange(0, 99)][double]$FpsLossPct = 5,
        [ValidateRange(0, 1000)][double]$P95RisePct = 10,
        [ValidateRange(0, 1000)][double]$P99RisePct = 15,
        [ValidateRange(100, 2147483647)][int]$MinIntervals = 1000,
        [ValidateRange(0, 100)][double]$DurationTolerancePct = 10
    )
    if ($Pairs.Count -lt 3) { throw 'At least three independent paired runs are required.' }
    $fps = @(); $p95 = @(); $p99 = @()
    foreach ($pair in $Pairs) {
        $a = $pair.Baseline; $b = $pair.Candidate
        foreach ($m in @($a, $b)) {
            if ($m.Intervals -lt $MinIntervals) { throw 'Too few intervals for the selected tail metrics.' }
            foreach ($name in @('DurationSeconds', 'PresentFPS', 'P95Ms', 'P99Ms')) {
                $v = [double]$m.$name
                if (-not [double]::IsFinite($v) -or $v -le 0) { throw "Invalid metric: $name" }
            }
        }
        if (100 * [Math]::Abs($b.DurationSeconds / $a.DurationSeconds - 1) -gt $DurationTolerancePct) {
            throw 'Paired capture durations differ beyond tolerance.'
        }
        $fps += 100 * (1 - $b.PresentFPS / $a.PresentFPS)
        $p95 += 100 * ($b.P95Ms / $a.P95Ms - 1)
        $p99 += 100 * ($b.P99Ms / $a.P99Ms - 1)
    }
    $report = foreach ($metric in @(
        @{ Name = 'PresentFPS loss'; Values = $fps; Limit = $FpsLossPct }
        @{ Name = 'P95 interval rise'; Values = $p95; Limit = $P95RisePct }
        @{ Name = 'P99 interval rise'; Values = $p99; Limit = $P99RisePct }
    )) {
        $median = Get-MedianValue -Values $metric.Values
        if (-not [double]::IsFinite($median)) { throw 'Non-finite relative change.' }
        [pscustomobject]@{
            Metric = $metric.Name
            MedianRegressionPct = $median
            LimitPct = $metric.Limit
            ExceedsLimit = $median -gt $metric.Limit
            PairedChangesPct = @($metric.Values)
        }
    }
    return [pscustomobject]@{
        Pairs = $Pairs.Count
        Passed = -not ($report.ExceedsLimit -contains $true)
        Metrics = @($report)
    }
}
