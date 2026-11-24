# Repeatable CPU scaling benchmark. Output JSON lines; no title execution.
[CmdletBinding()]
param(
    [int[]]$WorkerCounts=@(1,2,4,8,16,32),
    [ValidateRange(1,10)][int]$Repeats=3,
    [ValidateRange(1,4096)][int]$Items=256,
    [ValidateRange(1,1000000)][int]$Rounds=20000,
    [switch]$IncludeCacheGroups,
    [switch]$IncludeSmtComparison,
    [string]$VictoryExe,
    [string]$InputDirectory,
    [ValidateRange(1,600)][int]$TimeoutSeconds=120
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'CpuScaling.ps1')
if (-not $IsWindows) { throw 'Windows PowerShell 7+ required.' }
if (@($WorkerCounts).Count -eq 0 -or @($WorkerCounts | Where-Object { $_ -lt 1 -or $_ -gt 64 }).Count -gt 0) { throw 'Worker counts must be 1..64.' }
if ([bool]$VictoryExe -ne [bool]$InputDirectory) { throw 'Supply both VictoryExe and InputDirectory, or neither.' }
if ($VictoryExe) {
    $VictoryExe=(Resolve-Path -LiteralPath $VictoryExe).ProviderPath
    $InputDirectory=(Resolve-Path -LiteralPath $InputDirectory).ProviderPath
    $root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    if (-not (Test-Path -LiteralPath $VictoryExe -PathType Leaf) -or -not (Test-Path -LiteralPath $InputDirectory -PathType Container)) { throw 'Invalid input.' }
    if ($InputDirectory.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or
        $InputDirectory.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Use authorized input outside the repository.' }
}
$modes=@()
try {
    $topology=[VictoryCpuScaling]::Discover()
    $modes=@(Get-ScalingModes $topology -IncludeSmtComparison:$IncludeSmtComparison |
        Where-Object { $_.name -eq 'default' -or ($IncludeCacheGroups -and $_.name -like '*l3*') -or ($IncludeSmtComparison -and $_.name -eq 'one-logical-per-core') })
} catch {
    if ($IncludeCacheGroups -or $IncludeSmtComparison) { throw }
    $modes=@([pscustomobject]@{name='default';mask=[uint64]0;apply=$false;logical=[Environment]::ProcessorCount})
}
if ($IncludeCacheGroups -and @($modes | Where-Object { $_.name -like 'l3-*' }).Count -lt 2) { throw 'Two available verified L3 groups required; no CCD inferred.' }
if ($IncludeSmtComparison -and @($modes | Where-Object { $_.name -eq 'one-logical-per-core' }).Count -ne 1) { throw 'SMT comparison unavailable.' }
$conditions=@()
foreach ($mode in $modes) {
    foreach ($n in @($WorkerCounts | Sort-Object -Unique)) {
        if ($n -le $mode.logical) { $conditions += [pscustomobject]@{mode=$mode;workers=$n} }
    }
}
if ($conditions.Count -eq 0) { throw 'No requested worker count fits the available CPUs.' }
$reference=$null
$pwsh=Join-Path $PSHOME 'pwsh.exe'
$worker=Join-Path $PSScriptRoot 'Invoke-CpuScalingWorker.ps1'
$sha=if($VictoryExe){(Get-FileHash -LiteralPath $VictoryExe -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
for ($repeat=1; $repeat -le $Repeats; $repeat++) {
    $order=@($conditions)
    if ($repeat%2 -eq 0) { [array]::Reverse($order) }
    foreach ($condition in $order) {
        $mode=$condition.mode; $n=$condition.workers
        $argsList=@('-NoProfile','-NonInteractive','-File',$worker,'-Workers',"$n",'-Items',"$Items",'-Rounds',"$Rounds",'-TimeoutSeconds',"$TimeoutSeconds")
        if ($mode.apply) { $argsList+=@('-Mask',$mode.mask.ToString('x')) }
        if ($VictoryExe) { $argsList+=@('-VictoryExe',$VictoryExe,'-InputDirectory',$InputDirectory) }
        $raw=& $pwsh @argsList
        if ($LASTEXITCODE -ne 0) { throw 'Benchmark worker failed.' }
        $sample=$raw | ConvertFrom-Json
        $signature=if ($VictoryExe) { $sample.counts | ConvertTo-Json -Compress } else { $sample.checksum }
        if ($null -eq $reference) { $reference=$signature }
        if ($signature -ne $reference) { throw 'Workload output differs between conditions; comparison invalid.' }
        if ($sample.elapsedMs -le 0) { throw 'Invalid elapsed time.' }
        [pscustomobject]@{
            schema='victory.cpu.scaling.v1'; utc=[DateTime]::UtcNow.ToString('o')
            workload=if ($VictoryExe) {'offline-translation-census'} else {'synthetic-integer'}
            executableSha256=$sha; repeat=$repeat; mode=$mode.name; workers=$n; availableLogical=$mode.logical
            affinityMask=if ($mode.apply) {$mode.mask.ToString('x')} else {$null}
            elapsedMs=$sample.elapsedMs; workerProcessCpuMs=$sample.workerProcessCpuMs
            units=$sample.units; unitsPerSecond=1000.0*$sample.units/$sample.elapsedMs
            checksum=$sample.checksum; counts=$sample.counts; items=if($VictoryExe){$null}else{$Items}; rounds=if($VictoryExe){$null}else{$Rounds}
        } | ConvertTo-Json -Depth 5 -Compress
    }
}
