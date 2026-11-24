# System RAM profiling (V3.1 workflow 3)

Read-only Windows PowerShell 7+ collector. Start VIctory yourself and select its exact PID. Capture outside the repository:

    ./tools/diagnostics/Collect-Ram.ps1 -ProcessId 1234 -Samples 60 > C:\Benchmarks\cycle1.jsonl

Reports private bytes (committed private memory, not resident physical RAM), working set, sampled peaks, available system RAM, system commit/limit and cumulative system page-read-operation delta when CIM is available. Page reads are system-wide, not target-process hard faults. Missing fields are null; process hard faults and retained staging allocation counters are not yet implemented. Sampling is bounded, read-only and may add overhead; it does not stress memory or force paging.

Capture at least four separate, chronological equivalent workload cycles within the same process, with identical conditions and comparable end checkpoints. Then:

    ./tools/diagnostics/Compare-RamCycles.ps1 -Captures C:\Benchmarks\cycle1.jsonl,C:\Benchmarks\cycle2.jsonl,C:\Benchmarks\cycle3.jsonl,C:\Benchmarks\cycle4.jsonl

Default candidate threshold is 16 MiB, configurable. A candidate requires strictly increasing private bytes at every checkpoint and total growth at least the threshold. Stable/nonmonotonic growth is not proof of no leaks; monotonic growth can be normal caching or allocator retention. Confirm with longer controlled runs and allocation-level profiling. Compare equal scene/cycle endpoints; the tool cannot certify their equivalence. Raw logs stay outside the repository. Tests: tools/diagnostics/test-ram-metrics.ps1.
