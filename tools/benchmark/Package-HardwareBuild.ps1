# Package only the built VIctory executables, license and provenance.
# No local config, game files, caches, telemetry or captures are copied.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
$output = [IO.Path]::GetFullPath($OutputDirectory)
$prefix = $root.TrimEnd([char[]]@('/', '\')) + [IO.Path]::DirectorySeparatorChar
if ($output.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $output.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Package output must be outside the repository.'
}
if (Test-Path -LiteralPath $output) { throw 'Use a fresh output directory.' }
$commit = (git -C $root rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot determine source commit.' }
$rust = (rustc -Vv | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine toolchain.' }
New-Item -ItemType Directory -Path $output | Out-Null
$files = foreach ($profile in @('release', 'diag')) {
    $exe = Join-Path $root "target/$profile/victory.exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing $profile executable." }
    & $exe --version | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$profile version smoke test failed." }
    & $exe --help | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$profile help smoke test failed." }
    $name = "victory-$profile.exe"
    $dest = Join-Path $output $name
    Copy-Item -LiteralPath $exe -Destination $dest
    [pscustomobject]@{
        file = $name
        profile = $profile
        sha256 = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $dest).Length
    }
}
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $output
# Allowlist only source-controlled local benchmark helpers and guides.
$bundlePaths = @(
    'docs/asset-policy.md'
    'docs/asset-streaming-io-profiling.md'
    'docs/combined-hardware-report.md'
    'docs/cpu-hardware-diagnostics.md'
    'docs/cpu-thread-scaling.md'
    'docs/hardware-benchmark.md'
    'docs/hardware-regression-gate.md'
    'docs/hardware-validation-build.md'
    'docs/nvme-storage-profiling.md'
    'docs/performance-regression.md'
    'docs/ram-vram-transfer-benchmark.md'
    'docs/system-ram-profiling.md'
    'docs/v3-1-development-roadmap.md'
    'tools/benchmark/Compare-Presents.ps1'
    'tools/benchmark/CpuScaling.ps1'
    'tools/benchmark/HardwareRegressionMetrics.ps1'
    'tools/benchmark/Invoke-CpuScalingWorker.ps1'
    'tools/benchmark/PresentMetrics.ps1'
    'tools/benchmark/RegressionMetrics.ps1'
    'tools/benchmark/Test-CpuScaling.ps1'
    'tools/benchmark/Test-HardwareRegression.ps1'
    'tools/benchmark/Test-PresentRegression.ps1'
    'tools/benchmark/Test-StorageReads.ps1'
    'tools/diagnostics/Collect-Cpu.ps1'
    'tools/diagnostics/Collect-Ram.ps1'
    'tools/diagnostics/Collect-Storage.ps1'
    'tools/diagnostics/Compare-RamCycles.ps1'
    'tools/diagnostics/CpuMetrics.ps1'
    'tools/diagnostics/HardwareReportMetrics.ps1'
    'tools/diagnostics/New-HardwareReport.ps1'
    'tools/diagnostics/README.md'
    'tools/diagnostics/RamMetrics.ps1'
    'tools/diagnostics/StorageMetrics.ps1'
    'tools/diagnostics/compare-logs.sh'
)
$bundle = foreach ($relative in $bundlePaths) {
    $source = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing package helper: $relative" }
    $dest = Join-Path $output $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $dest
    [pscustomobject]@{file=$relative;sha256=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $dest).Length}
}

[pscustomobject]@{
    sourceCommit = $commit
    source = "https://github.com/James-Arthur-Gericke/VIctory/tree/$commit"
    rustc = $rust
    target = 'Windows x64 (host)'
    files = @($files)
    helpers = @($bundle)
    validation = 'CLI help/version smoke only; no title or GPU validation'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'build-manifest.json') -Encoding utf8
Write-Host 'Experimental hardware build package created.'
