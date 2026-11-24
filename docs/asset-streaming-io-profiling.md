# Asset streaming and cache I/O profiling (V3.1 workflow 6)

Diagnostics build only. Opt in before launching an authorized local run:

    $env:VICTORY_ASSET_IO_PROFILE = '1'

Use identical settings and separate external cache directories for new-cache runs. Warm each build separately before warm-cache comparisons. A new shader cache does not imply a cold OS filesystem cache. Record scene/phase start and end, build SHA, driver and instrumentation settings. Repeat at least three matched runs. Never delete an existing user cache or commit raw logs.

The runtime emits cumulative asset io samples by phase on the first completed operation and at most once per second while that phase is active. Reporting does not require presented frames, but a quiet final tail or a permanently stuck operation may not appear. Use deltas between matching cumulative samples. Counts and worker elapsed microseconds are inclusive, overlapping across workers; do not sum nested phases or infer device busy time.

- storage-request-inclusive: DirectStorage worker request duration, including reads, decompression and destination handling; source bytes credited on successful request only.
- storage-file-read: actual file seek-read loop, requested and completed bytes including partial failure; excludes memory-source copies.
- zlib / bcpack: output capacity and produced bytes (on success), measured decompression work; excludes unrelated queue waiting.
- shader-cache-read / pipeline-cache-read: successful file read bytes; requested bytes unknown (zero for these phases by convention). Missing cache files count as read failures, not necessarily runtime faults.
- shader-cache-decode: encoded bytes processed, separate from file read; existing shader profiling remains inclusive.
- No generic Win32 ReadFile/fread, memory mapped file, OS cache miss, pipeline cache write or full title streaming coverage. Existing logs may contain sensitive details; these added aggregate lines contain no paths, data, offsets, tags or shader names.

Correlate with process/disk counters and frame summaries only using matching time windows. A stall can originate in storage, scheduling, decompression, shader translation or GPU waiting. This change does not automatically identify causality, benchmark hardware, speed up reads, or change the scheduler. Workspace default and diagnostics regression tests include synthetic counter/partial-error/saturation and actual temporary-file success/failure tests. Existing DirectStorage raw and compressed fixtures continue to test correctness. No title or physical hardware is required in CI.
