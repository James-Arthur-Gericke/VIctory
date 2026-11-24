$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'HardwareRegressionMetrics.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Make-Run($Id,$Sha,$Fps=100,$Dropped=0,$Ram=100) {
    [pscustomobject]@{schema='victory.hardware.report.v1';runId=$Id;buildSha=($Sha*40);conditionsKey='fixture';durationSeconds=20
        visualCorrect=$true;deviceRemoved=$false;windowAligned=$true;diskInstance='disk';gpuAdapter='gpu';maxSkewMs=1500
        metrics=[pscustomobject]@{
            presentFps=[pscustomobject]@{value=$Fps;unit='fps';samples=2000}
            presentP95Ms=[pscustomobject]@{value=10;unit='ms';samples=2000}
            presentP99Ms=[pscustomobject]@{value=20;unit='ms';samples=2000}
            droppedDrawsPerFrame=[pscustomobject]@{value=$Dropped;unit='draws/frame';samples=5}
            ramPrivatePeakBytes=[pscustomobject]@{value=$Ram;unit='bytes';samples=5}
        }}
}
function Make-Pairs($Fps=100,$Ram=100) {
    foreach($i in 1..3){[pscustomobject]@{baseline=(Make-Run "a$i" 'a');candidate=(Make-Run "b$i" 'b' $Fps 0 $Ram)}}
}
$empty=[pscustomobject]@{}
Assert ((Test-HardwareRegression @(Make-Pairs 110) $empty).passed) 'Improvement.'
Assert (-not (Test-HardwareRegression @(Make-Pairs 90) $empty).passed) 'FPS regression.'
$p=@(Make-Pairs);$p[0].candidate.metrics.presentFps.value=50
Assert ((Test-HardwareRegression $p $empty).passed) 'Median tolerates one noisy pair.'
$p[0].candidate.metrics.droppedDrawsPerFrame.value=1
Assert (-not (Test-HardwareRegression $p $empty).passed) 'One increased dropped-draw pair fails.'
$p=@(Make-Pairs);$p[1].candidate.visualCorrect=$false
Assert ((Test-HardwareRegression $p $empty).status -eq 'correctness-failed') 'Black scene cannot pass.'
$p=@(Make-Pairs);$p[0].candidate.deviceRemoved=$true
Assert ((Test-HardwareRegression $p $empty).status -eq 'correctness-failed') 'Device removal.'
Assert (-not (Test-HardwareRegression @(Make-Pairs 100 130) ([pscustomobject]@{ramPrivatePeakBytes=10})).passed) 'RAM regression.'
function Must-Fail([scriptblock]$Work) {$failed=$false;try {&$Work | Out-Null}catch{$failed=$true};Assert $failed 'Expected invalid comparison.'}
$p=@(Make-Pairs);$p[0].candidate.metrics.presentP99Ms.value=$null
Must-Fail {Test-HardwareRegression $p $empty}
$p=@(Make-Pairs);$p[0].candidate.metrics.presentFps.samples=99
Must-Fail {Test-HardwareRegression $p $empty}
$p=@(Make-Pairs);$p[1].candidate.conditionsKey='other'
Must-Fail {Test-HardwareRegression $p $empty}
$p=@(Make-Pairs);$p[1].candidate.runId='b1'
Must-Fail {Test-HardwareRegression $p $empty}
$lines=@(1..3 | ForEach-Object {"transfer-v1 adapter=hardware vendor=0x10de device=0x1 luid=00000000:00000001 repeat=$_ pooled=true region_bytes=4096 bytes=16384 allocation_ms=1 staging_ms=1 upload_fence_ms=1 readback_fence_ms=1 verified=true"})
$m=Read-TransferMetric $lines 4096 $true '0x10de:0x1:00000000:00000001'
Assert ($m.samples -eq 3 -and $m.value -eq 15.625) 'Transfer throughput.'
Must-Fail {Read-TransferMetric ($lines+@($lines[0])) 4096 $true '0x10de:0x1:00000000:00000001'}
Must-Fail {Read-TransferMetric $lines 4096 $true 'wrong'}
# Full CLI and exit codes with independent synthetic reports.
$dir=Join-Path ([IO.Path]::GetTempPath()) ('victory-regression-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $pairs=@(foreach($p in @(Make-Pairs)){
        $a=$p.baseline.runId+'.json';$b=$p.candidate.runId+'.json'
        $p.baseline | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir $a)
        $p.candidate | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir $b)
        @{baseline=@{report=$a};candidate=@{report=$b}}
    })
    $manifest=[pscustomobject]@{schema='victory.hardware.regression.manifest.v1';comparable=$true;pairs=$pairs}
    $file=Join-Path $dir 'manifest.json';$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file
    $exe=Join-Path $PSHOME 'pwsh.exe';$script=Join-Path $PSScriptRoot 'Test-HardwareRegression.ps1'
    $output=& $exe -NoProfile -File $script -Manifest $file
    Assert ($LASTEXITCODE -eq 0 -and ($output | ConvertFrom-Json).passed) 'CLI success.'
    $candidate=Join-Path $dir 'b1.json';$run=Get-Content -Raw -LiteralPath $candidate | ConvertFrom-Json
    $run.visualCorrect=$false;$run | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $candidate
    $output=& $exe -NoProfile -File $script -Manifest $file
    Assert ($LASTEXITCODE -eq 1) 'CLI correctness failure.'
    $manifest.comparable=$false;$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file
    $output=& $exe -NoProfile -File $script -Manifest $file
    Assert ($LASTEXITCODE -eq 2) 'CLI invalid input.'
}finally{Remove-Item -LiteralPath $dir -Recurse -Force}
Write-Host 'Hardware regression tests passed.'
