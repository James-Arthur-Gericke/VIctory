# NVMe and storage profiling (V3.1 workflow 5)

Windows PowerShell 7+. Select an existing local VIctory process and save output outside the repository:

    ./tools/diagnostics/Collect-Storage.ps1 -ProcessId 1234 -Samples 60 > C:\Benchmarks\storage.jsonl

Process I/O counts read/write operations and transfer bytes including cached and non-disk I/O; these do not equal physical SSD bytes. PhysicalDisk CIM counters report per-instance throughput, instantaneous queue length and raw average timer deltas. Missing/first/reset counters and latency with no completed operations are null. Disk instances can span drives; identify the correct disk independently. CIM adds overhead. Do not attribute machine-wide activity to VIctory alone.

Optional synthetic buffered read test (explicit existing external directory on a fixed local drive):

    ./tools/benchmark/Test-StorageReads.ps1 -Directory C:\Benchmarks -SizeMiB 64 -Repeats 3

Creates a unique synthetic fixture (8–128 MiB), flushes writes, reads each block in sequential and deterministic permuted orders at 4 KiB and 1 MiB, alternates order, then deletes only its own file. Rejects repository-marker ancestors, redirected directories, remote/removable drives and insufficient free space. No raw-device access or cache eviction. Results are buffered end-to-end throughput and mean operation time including seeks and script overhead, not peak NVMe throughput, high-queue-depth random IOPS or a true cold-cache test. Newly written data may remain in OS cache. Does not validate the advertised 7,000 MB/s rating. CI uses a small synthetic fixture and no title.
