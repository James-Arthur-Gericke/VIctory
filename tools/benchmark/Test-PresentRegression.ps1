# Local captures only. Exit 0: within limits; 1: regression; 2: invalid input.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Manifest,
    [ValidateRange(0, 99)][double]$FpsLossPct = 5,
    [ValidateRange(0, 1000)][double]$P95RisePct = 10,
    [ValidateRange(0, 1000)][double]$P99RisePct = 15,
    [ValidateRange(100, 2147483647)][int]$MinIntervals = 1000,
    [ValidateRange(0, 100)][double]$DurationTolerancePct = 10
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PresentMetrics.ps1')
. (Join-Path $PSScriptRoot 'RegressionMetrics.ps1')

try {
    $manifestPath = (Resolve-Path -LiteralPath $Manifest).ProviderPath
    $root = Split-Path -Parent $manifestPath
    $spec = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($spec.Comparable -isnot [bool] -or -not $spec.Comparable) {
        throw 'Confirm same scene, settings, cache state and visual correctness with Comparable: true.'
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $hashes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pairs = foreach ($pair in $spec.Pairs) {
        $measured = @{}
        foreach ($side in @('Baseline', 'Candidate')) {
            $run = $pair.$side
            $file = [string]$run.Path
            if (-not [IO.Path]::IsPathRooted($file)) { $file = Join-Path $root $file }
            $file = (Resolve-Path -LiteralPath $file).ProviderPath
            if (-not $seen.Add($file) -or -not $hashes.Add((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash)) {
                throw 'A capture was reused; use independent recordings.'
            }
            $measured[$side] = Measure-PresentRows -Rows @(Import-Csv -LiteralPath $file) -ProcessId $run.ProcessId -SwapChain $run.SwapChain -Skip $run.Skip -Count $run.Count
        }
        [pscustomobject]$measured
    }
    $result = Test-PresentRegression -Pairs @($pairs) -FpsLossPct $FpsLossPct -P95RisePct $P95RisePct -P99RisePct $P99RisePct -MinIntervals $MinIntervals -DurationTolerancePct $DurationTolerancePct
    $result | ConvertTo-Json -Depth 6
    if (-not $result.Passed) { exit 1 }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
