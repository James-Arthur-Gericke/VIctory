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
[pscustomobject]@{
    sourceCommit = $commit
    source = "https://github.com/James-Arthur-Gericke/VIctory/tree/$commit"
    rustc = $rust
    target = 'Windows x64 (host)'
    files = @($files)
    validation = 'CLI help/version smoke only; no title or GPU validation'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'build-manifest.json') -Encoding utf8
Write-Host 'Experimental hardware build package created.'
