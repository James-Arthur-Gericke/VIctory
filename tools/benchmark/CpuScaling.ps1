Set-StrictMode -Version Latest

# Single processor-group x64 only: never guess CCD membership from CPU numbers.
# Legacy GLPI returns masks in the calling processor group.
if (-not ('VictoryCpuScaling' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
public static class VictoryCpuScaling {
    [DllImport("kernel32.dll")] public static extern ushort GetActiveProcessorGroupCount();
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetLogicalProcessorInformation(IntPtr buffer, ref uint length);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetProcessAffinityMask(IntPtr process, out UIntPtr processMask, out UIntPtr systemMask);
    public sealed class Topology {
        public ulong Allowed {get;set;}
        public ulong SystemMask {get;set;}
        public ulong[] Cores {get;set;}
        public ulong[] L3 {get;set;}
    }
    public static Topology Discover() {
        if (IntPtr.Size != 8 || GetActiveProcessorGroupCount() != 1)
            throw new NotSupportedException("Explicit affinity requires x64 and one processor group.");
        UIntPtr allowed, system;
        using (var p = Process.GetCurrentProcess()) {
            if (!GetProcessAffinityMask(p.Handle, out allowed, out system))
                throw new InvalidOperationException("Cannot query process affinity.");
        }
        uint size = 0;
        GetLogicalProcessorInformation(IntPtr.Zero, ref size);
        if (size == 0 || size > 1048576 || size % 32 != 0)
            throw new InvalidOperationException("Unexpected topology length.");
        IntPtr mem = Marshal.AllocHGlobal((int)size);
        try {
            if (!GetLogicalProcessorInformation(mem, ref size) || size % 32 != 0)
                throw new InvalidOperationException("Topology query failed.");
            var cores = new List<ulong>(); var l3 = new List<ulong>();
            for (int i = 0; i < size; i += 32) {
                ulong mask = unchecked((ulong)Marshal.ReadInt64(mem, i));
                int relation = Marshal.ReadInt32(mem, i + 8);
                // PROCESSOR_RELATIONSHIP: core=0, cache=2.
                // x64 CACHE_DESCRIPTOR union: Level at 16, Type at 24.
                if (relation == 0) cores.Add(mask);
                if (relation == 2 && Marshal.ReadByte(mem, i + 16) == 3 &&
                    Marshal.ReadInt32(mem, i + 24) == 0) l3.Add(mask); // unified
            }
            return new Topology { Allowed=allowed.ToUInt64(), SystemMask=system.ToUInt64(),
                Cores=cores.ToArray(), L3=l3.ToArray() };
        } finally { Marshal.FreeHGlobal(mem); }
    }
    public static int Count(ulong mask) {
        int n=0; while(mask!=0){mask &= mask-1; n++;} return n;
    }
    public static bool Partition(ulong whole, ulong[] parts) {
        if (whole==0 || parts==null || parts.Length==0) return false;
        ulong seen=0;
        foreach(ulong part in parts) {
            if(part==0 || (part & ~whole)!=0 || (part & seen)!=0) return false;
            seen |= part;
        }
        return seen==whole;
    }
    public static bool WholeCores(ulong[] groups, ulong[] cores) {
        foreach (ulong group in groups)
            foreach (ulong core in cores)
                if ((group & core) != 0 && (group & core) != core) return false;
        return true;
    }
    public static ulong OneThreadPerCore(ulong mask, ulong[] cores) {
        ulong result=0;
        foreach (ulong core in cores) {
            ulong available=core & mask;
            if (available!=0) result |= available & unchecked(0UL-available);
        }
        return result;
    }
    public static ulong ParseMask(string mask) {
        return Convert.ToUInt64(mask,16);
    }
    public static IntPtr AsIntPtr(ulong mask) {
        return new IntPtr(unchecked((long)mask));
    }
    public static ulong AsMask(IntPtr ptr) {
        return unchecked((ulong)ptr.ToInt64());
    }
    // Fixed independent items, no shared random state or order-dependent
    // reduction. Generic CPU workload, not a game or shader benchmark.
    public static ulong Work(int workers, int items, int rounds) {
        if (workers<1 || workers>64 || items<1 || items>4096 || rounds<1 || rounds>1000000)
            throw new ArgumentOutOfRangeException("work");
        var values=new ulong[items];
        Parallel.For(0, items, new ParallelOptions {MaxDegreeOfParallelism=workers}, i => {
            unchecked {
                ulong v=(ulong)i+1;
                for (int j=0;j<rounds;j++) {
                    v ^= v>>12; v ^= v<<25; v ^= v>>27; v *= 2685821657736338717UL;
                }
                values[i]=v;
            }
        });
        unchecked {
            ulong checksum=14695981039346656037UL;
            foreach(ulong v in values) checksum=(checksum^v)*1099511628211UL;
            return checksum;
        }
    }
}
'@
}

function Get-ScalingModes($Topology, [switch]$IncludeSmtComparison) {
    $allowed = [uint64]$Topology.Allowed
    $system = [uint64]$Topology.SystemMask
    if ($allowed -eq 0 -or ($allowed -band $system) -ne $allowed) { throw 'Invalid allowed mask.' }
    $cores = [uint64[]]$Topology.Cores
    $groups = [uint64[]]$Topology.L3
    $verifiedCores = [VictoryCpuScaling]::Partition($system,$cores)
    # Only label separate L3 groups when both partitions are complete and
    # every physical core belongs wholly to one cache group.
    $verifiedL3 = $verifiedCores -and $groups.Count -ge 2 -and
        [VictoryCpuScaling]::Partition($system,$groups) -and [VictoryCpuScaling]::WholeCores($groups,$cores)
    [pscustomobject]@{ name='default'; mask=$allowed; apply=$false; logical=[VictoryCpuScaling]::Count($allowed) }
    if ($verifiedL3) {
        $union = [uint64]0; $availableGroups = 0
        for ($i=0; $i -lt $groups.Count; $i++) {
            $mask = $groups[$i] -band $allowed
            if ($mask -eq 0) { continue }
            $union = $union -bor $mask; $availableGroups++
            [pscustomobject]@{ name="l3-$i"; mask=$mask; apply=$true; logical=[VictoryCpuScaling]::Count($mask) }
        }
        if ($availableGroups -ge 2) {
            [pscustomobject]@{ name='all-l3'; mask=$union; apply=$true; logical=[VictoryCpuScaling]::Count($union) }
        }
    }
    if ($IncludeSmtComparison -and $verifiedCores) {
        $mask = [VictoryCpuScaling]::OneThreadPerCore($allowed,$cores)
        if ($mask -ne 0 -and $mask -ne $allowed) {
            [pscustomobject]@{ name='one-logical-per-core'; mask=$mask; apply=$true; logical=[VictoryCpuScaling]::Count($mask) }
        }
    }
}

# Only aggregate counts; no filenames, shader text or proprietary dump output.
function Get-TranslationCounts([string]$Output) {
    $patterns = @(
        '(?m)^containers\s+(\d+) \((\d+) duplicates skipped\)\s*$',
        '(?m)^programs\s+(\d+) translated of (\d+) \((\d+) IR instructions\)\s*$',
        '(?m)^DXIL\s+(\d+) emitted of (\d+) vertex and pixel programs; \d+ validated, \d+ pipelines\s*$',
        '(?m)^\s+(\d+) emitted of (\d+) compute programs; \d+ validated, \d+ pipelines\s*$',
        '(?m)^\s+(\d+) emitted of (\d+) mesh programs; \d+ validated, \d+ pipelines\s*$'
    )
    $v = @()
    foreach ($pattern in $patterns) {
        $m = [regex]::Matches($Output,$pattern)
        if ($m.Count -ne 1) { throw 'Translation summary missing or ambiguous.' }
        for ($i=1; $i -lt $m[0].Groups.Count; $i++) { $v += [int64]$m[0].Groups[$i].Value }
    }
    [pscustomobject]@{
        containers=$v[0]; duplicates=$v[1]; translated=$v[2]; programs=$v[3]; instructions=$v[4]
        graphicsEmitted=$v[5]; graphicsPrograms=$v[6]; computeEmitted=$v[7]; computePrograms=$v[8]; meshEmitted=$v[9]; meshPrograms=$v[10]
    }
}
