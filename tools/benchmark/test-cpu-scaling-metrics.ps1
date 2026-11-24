$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'CpuScaling.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$top=[pscustomobject]@{Allowed=[uint64]255;SystemMask=[uint64]255;Cores=[uint64[]]@(3,12,48,192);L3=[uint64[]]@(15,240)}
$m=@(Get-ScalingModes $top -IncludeSmtComparison)
Assert ($m.Count -eq 5) 'Expected default, two L3 groups, union and SMT comparison.'
Assert ($m[1].logical -eq 4 -and $m[2].mask -eq 240 -and $m[3].mask -eq 255) 'Cache masks.'
Assert ($m[4].mask -eq 85) 'One logical processor per core.'
$top.Allowed=[uint64]3
$m=@(Get-ScalingModes $top)
Assert ($m.Count -eq 2 -and $m[1].mask -eq 3) 'Restricted affinity must not invent another group.'
$top.Allowed=[uint64]255; $top.L3=[uint64[]]@(31,240)
Assert (@(Get-ScalingModes $top).Count -eq 1) 'Reject overlapping cache groups.'
$top.L3=[uint64[]]@(5,250)
Assert (@(Get-ScalingModes $top).Count -eq 1) 'Reject cache groups splitting cores.'
Assert ([VictoryCpuScaling]::Work(1,32,100) -eq [VictoryCpuScaling]::Work(4,32,100)) 'Worker result differs.'
Assert ([VictoryCpuScaling]::AsMask([VictoryCpuScaling]::AsIntPtr([uint64]::MaxValue)) -eq [uint64]::MaxValue) 'High affinity bits.'
$fixture=@'
containers   8 (2 duplicates skipped)
programs     4 translated of 5 (80 IR instructions)
DXIL         1 emitted of 2 vertex and pixel programs; 0 validated, 0 pipelines
             2 emitted of 2 compute programs; 0 validated, 0 pipelines
             0 emitted of 1 mesh programs; 0 validated, 0 pipelines
'@
$c=Get-TranslationCounts $fixture
Assert ($c.programs -eq 5 -and $c.computeEmitted -eq 2) 'Translation aggregate parser.'
$failed=$false
try { Get-TranslationCounts 'invalid' } catch {$failed=$true}
Assert $failed 'Missing summary must fail.'
$rows=@(& (Join-Path $PSScriptRoot 'Test-CpuScaling.ps1') -WorkerCounts 1 -Repeats 2 -Items 8 -Rounds 100 | ForEach-Object {$_ | ConvertFrom-Json})
Assert ($rows.Count -eq 2 -and $rows[0].checksum -eq $rows[1].checksum -and $rows[1].elapsedMs -gt 0) 'Windows child smoke.'
Write-Host 'CPU scaling tests passed.'
