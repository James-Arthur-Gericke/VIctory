# Internal worker: launched in a fresh PowerShell process by the benchmark.
[CmdletBinding()]
param([int]$Workers,[int]$Items,[int]$Rounds,[string]$Mask,[string]$VictoryExe,[string]$InputDirectory,[int]$TimeoutSeconds=120)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'CpuScaling.ps1')
$self = [Diagnostics.Process]::GetCurrentProcess()
$old = $self.ProcessorAffinity
try {
    if ($Mask) {
        $requested = [VictoryCpuScaling]::ParseMask($Mask)
        $allowed = [VictoryCpuScaling]::AsMask($old)
        if ($requested -eq 0 -or ($requested -band $allowed) -ne $requested) { throw 'Affinity outside inherited mask.' }
        $self.ProcessorAffinity = [VictoryCpuScaling]::AsIntPtr($requested)
        $self.Refresh()
        if ([VictoryCpuScaling]::AsMask($self.ProcessorAffinity) -ne $requested) { throw 'Affinity verification failed.' }
    }
    $before = $self.TotalProcessorTime.TotalMilliseconds
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $counts = $null; $checksum = $null
    if ($VictoryExe) {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $VictoryExe; $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        # Offline census only; no D3D pipeline, validator, dump or pair options.
        foreach ($arg in @('translate',$InputDirectory,'--jobs',"$Workers")) { $info.ArgumentList.Add($arg) }
        foreach ($key in @($info.Environment.Keys)) {
            if ($key.StartsWith('VICTORY_', [StringComparison]::OrdinalIgnoreCase)) { [void]$info.Environment.Remove($key) }
        }
        $p = [Diagnostics.Process]::Start($info)
        try {
            $out = $p.StandardOutput.ReadToEndAsync()
            $err = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit($TimeoutSeconds*1000)) {
                try { $p.Kill($true); $p.WaitForExit() } catch { }
                throw 'Offline translation timeout.'
            }
            $stdout = $out.GetAwaiter().GetResult()
            [void]$err.GetAwaiter().GetResult()
            if ($p.ExitCode -ne 0) { throw "Offline translation failed (exit $($p.ExitCode))." }
            $counts = Get-TranslationCounts $stdout
            if ($counts.programs -le 0) { throw 'No shader programs found; not a meaningful benchmark.' }
        } finally { $p.Dispose() }
    } else {
        $checksum = [VictoryCpuScaling]::Work($Workers,$Items,$Rounds).ToString('x16')
    }
    $watch.Stop(); $self.Refresh()
    [pscustomobject]@{
        elapsedMs=$watch.Elapsed.TotalMilliseconds
        workerProcessCpuMs=if ($VictoryExe) { $null } else { $self.TotalProcessorTime.TotalMilliseconds-$before }
        checksum=$checksum; counts=$counts
        units=if ($VictoryExe) { $counts.programs } else { $Items }
    } | ConvertTo-Json -Depth 4 -Compress
} finally {
    if ($Mask) { $self.ProcessorAffinity=$old }
    $self.Dispose()
}
