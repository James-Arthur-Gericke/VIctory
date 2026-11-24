# Exit 0 within limits; 1 regression/correctness failure; 2 invalid/insufficient.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Manifest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'HardwareRegressionMetrics.ps1')
try {
    $path=(Resolve-Path -LiteralPath $Manifest).ProviderPath
    $root=Split-Path -Parent $path
    $spec=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($spec.schema -ne 'victory.hardware.regression.manifest.v1' -or $spec.comparable -isnot [bool] -or -not $spec.comparable) {throw 'Explicit comparable-run confirmation required.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $hashes=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Read-UniqueFile([string]$File) {
        if (-not [IO.Path]::IsPathRooted($File)) {$File=Join-Path $root $File}
        $File=(Resolve-Path -LiteralPath $File).ProviderPath
        if (-not $seen.Add($File) -or -not $hashes.Add((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash)) {throw 'Reused capture path or content.'}
        return $File
    }
    $transfer=Get-HardwareField $spec 'transfer'
    $thresholds=Get-HardwareField $spec 'thresholds'
    if ($null -eq $thresholds) {$thresholds=[pscustomobject]@{}}
    $transferRequired=$null -ne $thresholds.PSObject.Properties['transferUploadMiBps']
    if ($transferRequired -ne ($null -ne $transfer)) {throw 'Specify transfer configuration and threshold together.'}
    if ($transferRequired -and ($transfer.pooled -isnot [bool] -or [string]::IsNullOrWhiteSpace($transfer.adapterIdentity))) {throw 'Invalid transfer condition.'}
    $pairs=@(foreach($pair in $spec.pairs) {
        $runs=@{}
        foreach($side in @('baseline','candidate')) {
            $entry=$pair.$side
            $file=Read-UniqueFile $entry.report
            $run=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if ($transferRequired) {
                $tf=Read-UniqueFile $entry.transferLog
                $metric=Read-TransferMetric (Get-Content -LiteralPath $tf) $transfer.regionBytes $transfer.pooled $transfer.adapterIdentity
                $run.metrics | Add-Member -NotePropertyName transferUploadMiBps -NotePropertyValue $metric -Force
            }
            $runs[$side]=$run
        }
        [pscustomobject]$runs
    })
    $tol=Get-HardwareField $spec 'durationTolerancePct'
    if ($null -eq $tol) {$tol=10}
    $result=Test-HardwareRegression $pairs $thresholds $tol
    $result | ConvertTo-Json -Depth 6
    if ($result.passed) {exit 0}
    exit 1
} catch {
    [pscustomobject]@{schema='victory.hardware.regression.v1';passed=$false;status='insufficient-or-invalid';reason=$_.Exception.Message} | ConvertTo-Json -Compress
    exit 2
}
