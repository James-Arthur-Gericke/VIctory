# Supply one end-of-cycle private-byte checkpoint per equivalent cycle.
[CmdletBinding()]
param([Parameter(Mandatory)][string[]]$Captures,
      [ValidateRange(1,1099511627776)][long]$ThresholdBytes=16777216)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RamMetrics.ps1')
$checkpoints=@(); $identity=$null; $lastUtc=$null
foreach ($file in $Captures) {
    $rows=@(Get-Content -LiteralPath $file | ForEach-Object { $_ | ConvertFrom-Json })
    if ($rows.Count -lt 2) { throw 'Each cycle requires at least two samples.' }
    $row=$rows[-1]
    $key="$($row.processId):$($row.processStartUtcTicks)"
    if ($null -eq $identity) { $identity=$key }
    if ($key -ne $identity) { throw 'Compare repeated equivalent cycles in the same process.' }
    $previousElapsed=-1
    foreach ($r in $rows) {
        if ($r.schema -ne 'victory.ram.sample.v1' -or "$($r.processId):$($r.processStartUtcTicks)" -ne $identity -or $r.elapsedMs -le $previousElapsed) {
            throw 'Invalid sample sequence or mixed process.'
        }
        $previousElapsed=$r.elapsedMs
    }
    $first=[DateTimeOffset]::Parse($rows[0].utc); $end=[DateTimeOffset]::Parse($row.utc)
    if ($end -le $first -or ($null -ne $lastUtc -and $first -le $lastUtc)) { throw 'Cycles must be chronological and nonoverlapping.' }
    $lastUtc=$end
    $checkpoints+= $row.privateBytes
}
$result=Get-RamTrend $checkpoints $ThresholdBytes
[pscustomobject]@{
    schema='victory.ram.trend.v1'; cycles=$checkpoints.Count; thresholdBytes=$ThresholdBytes
    status=$result.status; growthBytes=$result.growthBytes; peakCheckpointBytes=$result.peakBytes
    note='Candidate growth only; normal caches and allocator retention can grow.'
} | ConvertTo-Json -Compress
