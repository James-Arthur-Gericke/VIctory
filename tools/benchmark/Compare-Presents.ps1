# Compare two locally captured PresentMon CSV files. No capture is uploaded.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Baseline,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][uint32]$BaselineProcessId,
    [Parameter(Mandatory)][uint32]$CandidateProcessId,
    [Parameter(Mandatory)][string]$BaselineSwapChain,
    [Parameter(Mandatory)][string]$CandidateSwapChain,
    [ValidateRange(1, 2147483647)][int]$BaselineSkip = 1,
    [ValidateRange(1, 2147483647)][int]$CandidateSkip = 1,
    [ValidateRange(0, 2147483647)][int]$BaselineCount = 0,
    [ValidateRange(0, 2147483647)][int]$CandidateCount = 0
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PresentMetrics.ps1')

$a = Measure-PresentRows -Rows @(Import-Csv -LiteralPath $Baseline) -ProcessId $BaselineProcessId -SwapChain $BaselineSwapChain -Skip $BaselineSkip -Count $BaselineCount
$b = Measure-PresentRows -Rows @(Import-Csv -LiteralPath $Candidate) -ProcessId $CandidateProcessId -SwapChain $CandidateSwapChain -Skip $CandidateSkip -Count $CandidateCount

Write-Host 'Application present intervals (not displayed or successfully rendered frames).'
Write-Host 'Verify scene, hardware, driver, cache state, capture duration and settings match.'
$report = foreach ($name in @('Intervals', 'DurationSeconds', 'PresentFPS', 'MeanMs', 'P50Ms', 'P95Ms', 'P99Ms', 'MaxMs')) {
    [pscustomobject]@{
        Metric = $name
        Baseline = [Math]::Round([double]$a.$name, 3)
        Candidate = [Math]::Round([double]$b.$name, 3)
        Delta = [Math]::Round([double]$b.$name - [double]$a.$name, 3)
    }
}
$report | Format-Table -AutoSize
