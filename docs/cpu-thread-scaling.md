# CPU thread scaling and cache topology (V3.1 workflow 2)

Run from the repository root with Windows PowerShell 7+. This is an independent V3-based local benchmark, not a runtime scheduler change. Start with a generic CPU integer workload; workers produce the same checksum at each setting. The runner launches a fresh PowerShell process per condition, alternates condition order and checks output equivalence. Results are JSON lines (save outside the repository).

    ./tools/benchmark/Test-CpuScaling.ps1 -Repeats 3 > C:\Benchmarks\cpu-scaling.jsonl

For explicit affinity comparisons on the Ryzen 9 9950X3D2:

    ./tools/benchmark/Test-CpuScaling.ps1 -IncludeCacheGroups -IncludeSmtComparison > C:\Benchmarks\cpu-topology.jsonl

Native Windows GetLogicalProcessorInformation supplies physical core and unified L3 masks. Explicit affinity is limited to x64 machines with one processor group, and to the inherited process mask. Cache groups must form a disjoint complete partition and must not split physical cores. The masks are L3-sharing groups, a practical CCD proxy on this target, not a universal CCD identification method. OS-default scheduling is compared with each available L3 group and their union; one logical thread per core is a separate mode, not a BIOS SMT toggle. Worker counts larger than the available logical CPU count in a condition are omitted. If requested topology modes cannot be validated, fail rather than guess. Affinity changes only the temporary worker process and is restored on exit. No global scheduler/BIOS changes.

Optional actual CPU-only offline shader census (use an authorized external directory, with the exact built executable):

    ./tools/benchmark/Test-CpuScaling.ps1 -VictoryExe C:\Builds\victory-release.exe -InputDirectory C:\AuthorizedInputs -Repeats 3 > C:\Benchmarks\shader-scaling.jsonl

The worker invokes the existing translate --jobs path, without --validate, --pipelines, --list or VICTORY_* environment overrides. It captures only aggregate census counts and rejects mismatched counts, missing summaries, empty workloads, failed exit codes and timeouts. The child inherits the temporary worker's single-group affinity on Windows. Counts include program/IR/DXIL emission totals; equality is not proof of byte-identical DXIL or identical failure reasons. A failed condition aborts comparison. Keep the corpus fixed and read-only. No game launch or graphics adapter required. Timing includes process start and disk reads for offline census; it does not isolate compilation or guarantee a cold filesystem cache. Record cache conditions externally; do not force cache eviction. A fresh process is not a cold disk. Compare equivalent conditions and at least three repeats. Synthetic throughput is items/s, offline throughput is programs/s, not game FPS. This does not measure cache misses or prove a 3D V-Cache gain. Test script: tools/benchmark/test-cpu-scaling-metrics.ps1.
