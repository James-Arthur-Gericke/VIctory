# Opt-in buffered synthetic reads; no raw devices or cache flushing.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Directory,
      [ValidateSet(8,16,32,64,128)][int]$SizeMiB=64,
      [ValidateRange(1,5)][int]$Repeats=3)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../diagnostics/StorageMetrics.ps1')
if (-not $IsWindows) { throw 'Windows PowerShell 7+ required.' }
$dir=Get-Item -LiteralPath $Directory
if ($dir -isnot [IO.DirectoryInfo]) { throw 'Select an existing external directory.' }
if ($dir.FullName -notmatch '^[A-Za-z]:\\') { throw 'Select a local drive.' }
for ($a=$dir; $null -ne $a; $a=$a.Parent) {
    if (($a.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Test-Path -LiteralPath (Join-Path $a.FullName '.victory-root'))) { throw 'Repository or redirected directory refused.' }
}
$drive=[IO.DriveInfo]::new($dir.Root.FullName)
if ($drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'Select a fixed local drive.' }
$bytes=[long]$SizeMiB*1MB
if ($drive.AvailableFreeSpace -lt ($bytes+64MB)) { throw 'Insufficient free space.' }
$path=Join-Path $dir.FullName ("victory-synthetic-"+[Guid]::NewGuid().ToString('N')+".tmp")
$owned=$false
try {
    $buffer=[byte[]]::new(1MB)
    $rng=[Random]::new(731)
    $file=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $owned=$true
    try {
        for ($i=0;$i -lt $SizeMiB;$i++) {
            $rng.NextBytes($buffer)
            $file.Write($buffer,0,$buffer.Length)
        }
        $file.Flush($true)
    } finally { $file.Dispose() }
    foreach ($blockSize in @(4096,1048576)) {
        $blocks=[int]($bytes/$blockSize)
        $data=[byte[]]::new($blockSize)
        for ($repeat=1;$repeat -le $Repeats;$repeat++) {
            foreach ($random in @((($repeat%2) -eq 0),(($repeat%2) -ne 0))) {
                $file=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,4096,[IO.FileOptions]::None)
                try {
                    $watch=[Diagnostics.Stopwatch]::StartNew()
                    for ($i=0;$i -lt $blocks;$i++) {
                        $idx=Get-ReadBlockIndex $i $blocks $random
                        $file.Position=[long]$idx*$blockSize
                        $file.ReadExactly($data,0,$data.Length)
                    }
                    $watch.Stop()
                    $seconds=$watch.Elapsed.TotalSeconds
                    if ($seconds -le 0) { throw 'Invalid timer.' }
                    [pscustomobject]@{
                        schema='victory.storage.read.v1'; utc=[DateTime]::UtcNow.ToString('o')
                        repeat=$repeat; order=if($random){'permuted'}else{'sequential'}
                        bytes=$bytes; blockBytes=$blockSize; operations=$blocks; elapsedMs=$seconds*1000
                        bytesPerSecond=$bytes/$seconds; meanEndToEndOperationMs=$seconds*1000/$blocks
                        cacheCondition='buffered-after-file-creation'; driveFreeBytes=$drive.AvailableFreeSpace
                    } | ConvertTo-Json -Compress
                } finally { $file.Dispose() }
            }
        }
    }
} finally { if ($owned) { Remove-Item -LiteralPath $path -ErrorAction Stop } }
