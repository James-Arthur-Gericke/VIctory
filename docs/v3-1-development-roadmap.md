# Integration V3.1 — comprehensive hardware validation roadmap

Status: eight implementation drafts assembled into a V3.1 integration candidate. Individual PRs #39–46 passed CI; #47's regression assertions passed but the test wrapper propagated a nonzero child exit status, corrected in its follow-up commit. Revalidation and combined CI are required. Unchecked roadmap items remain acceptance targets, not claims of completion. Baseline: Integration V3 (`ceba90a837b9700a4eecbad8cedd2a6cd3c30ab6`, PR #38), successful hosted Windows CI run 45417126172 (check and hardware-build). Preserve this baseline, V1/V2 and main. CI is not physical hardware validation.

## Reference platform

User-provided target: AMD Ryzen 9 9950X3D2 (16 cores / 32 threads), NVIDIA RTX 5090 (32 GB VRAM), 64 GB DDR5, 2 TB NVMe rated approximately 7,000 MB/s, Windows x64. Record the actual OS build, firmware, chipset and GPU driver, topology, RAM speed/timings and storage model at capture time. Advertised SSD sequential speed is not measured asset-streaming throughput. No hardware-specific assumption should become a mandatory runtime requirement.

## Nine independent workflows

Use separate draft branches/PRs based on the pinned V3 commit, or an explicitly documented prerequisite branch where needed. Mark a workflow implemented only after its code, synthetic tests and CI are verified. Keep optimisations separate from measurement wherever practical.

### 1. CPU hardware diagnostics infrastructure
- [ ] Discover logical processors, physical cores and processor groups; report process CPU time, elapsed time, thread count, per-thread activity and optional per-core sampling via supported Windows APIs.
- [ ] Record CPU clocks, temperatures, power and cache counters only when a supported external collector exposes them; otherwise mark unavailable. Distinguish sampled utilization from elapsed worker time.
- Acceptance: synthetic counter delta tests (reset, missing readings, zero interval), bounded opt-in logging, no assumed vendor-specific privileges or affinity changes.

### 2. CPU thread scaling and dual-CCD benchmarking
- [ ] Measure offline shader translation and suitable synthetic workloads at 1, 2, 4, 8, 16 and 32 workers; report throughput, latency and failure counts.
- [ ] Discover actual cache-sharing/core topology; compare OS-default scheduling, a single verified CCD/cache group and both groups. Keep SMT comparisons separate from worker counts. Apply optional affinity to test processes only, restore/default on exit, never change BIOS or global scheduling.
- Acceptance: deterministic worker/output equivalence checks, topology/affinity validation including unsupported layouts and fewer available CPUs, repeatable cold/warm measurements; no claimed 3D V-Cache gain until measured.

### 3. System RAM profiling and memory leak detection
- [ ] Sample process working set/private bytes, system commit/available memory and supported page-fault counters; record peaks and trends through matched workload phases.
- [ ] Track retained upload/staging allocations where feasible. Flag sustained growth across repeated equivalent cycles as a candidate leak, not proof; distinguish normal caching and allocator retention.
- Acceptance: bounded sampler; synthetic rising/stable/reset/missing samples; no automatic exhaustion, paging stress or forced cache deletion.

### 4. RAM-to-VRAM transfer benchmarking
- [ ] Measure CPU fill/copy cost separately from GPU fence-confirmed transfer completion, bytes and throughput using synthetic bounded buffers; include aligned and representative small/large sizes.
- [ ] Validate contents, correct D3D12 states and fence completion; compare pooled and dedicated paths. Report upload heap/staging behavior and GPU memory budgets separately from PCIe link bandwidth.
- Acceptance: correctness/failure/timeout tests, WARP only for functional checks, physical adapter opt-in and no reuse of in-flight memory.

### 5. NVMe storage performance profiling
- [ ] Capture process I/O read/write bytes/operations and supported disk latency, throughput and queue depth, distinguishing process I/O from physical disk activity.
- [ ] Optional bounded sequential/random read benchmark using only user-approved synthetic files in a separate external temporary directory; no raw-device access, destructive tests or forced cache eviction.
- Acceptance: validate input paths, sizes, units, missing counters and cleanup; distinguish warm-cache and new-file results, record free space.

### 6. Asset streaming and disk I/O benchmarking
- [ ] Profile file-read request counts, bytes, latency and errors where runtime hooks expose them; measure shader/pipeline cache read/decode and loading phases separately from storage waits.
- [ ] Compare cold (separate external cache directories) and warm runs, distinguish disk stalls from decompression, shader translation and GPU waiting. Do not infer all title streaming is observable.
- Acceptance: synthetic I/O fixtures and error cases; preserve file semantics and timing; redact paths and omit proprietary data from logs shared externally.

### 7. Combined CPU, GPU, RAM and SSD performance reporting
- [ ] Produce timestamped, versioned, machine-readable samples and a human-readable report with synchronized elapsed time, explicit units, sample counts and missing-data flags.
- [ ] Combine CPU/process/RAM/I/O collectors with existing V3 frame summaries, PresentMon interval metrics, GPU residency and shader profiling. Optional vendor telemetry for clocks, utilization, power and temperatures; report unavailable counters as null, never zero.
- Acceptance: synthetic correlation, time alignment, partial data, privacy and unit tests. Preserve diagnostic/release comparability; avoid adding overlapping CPU/GPU worker times.

### 8. Automated hardware performance regression detection
- [ ] Extend the existing PresentMon paired-capture regression gate with matched CPU, RAM, transfer and storage metrics; use at least three comparable repeated pairs, configurable thresholds and explicit insufficient-data results.
- [ ] Gate correctness first (scene renders, dropped draws, failures); lower frame times in a black scene are not a successful speedup. Compare equivalent driver, scene, settings, profile, instrumentation, topology and cache state.
- Acceptance: synthetic improvement/regression/noise/missing-data fixtures; deterministic results and documented exit codes. Do not assert benchmark thresholds without measurements.

### 9. Combined Integration V3.1
- [ ] Reconcile the eight validated workflows on a new integration branch, leaving V3/main unchanged. Review upstream overlap and interaction with resource ownership, fence completion and cache semantics.
- [ ] Run Windows default/all-features Clippy and workspace tests, asset policy, synthetic benchmark/collector/comparator tests, release/diagnostics builds, CLI smoke tests and exact-head SHA256 manifest packaging.
- [ ] Provide a local hardware procedure and report schema; use WARP first for correctness, then explicitly authorized supervised physical tests on the RTX 5090. Stop on device removal, hang or unsafe thermals; do not disable driver watchdogs or alter global settings.
- Acceptance: all combined CI checks pass; downloadable exact-head artifact; documented limitations and reproducible V3 vs V3.1 comparison. Physical measurements remain a separate milestone.

## Hardware validation protocol

Use authorized local test data only. Start with no-title synthetic checks, then WARP correctness checks, then controlled real hardware testing if appropriate. Use matched builds/profiles and identical instrumentation for A/B comparisons. Record CPU/GPU/RAM/storage configuration, scene, timestamps, cache condition and diagnostic flags; alternate run order, repeat at least three times, and retain raw logs locally outside the repo. Review the documented real GPU driver-reset risk before testing.

V3.1 measures and diagnoses; it is not a promise of improved FPS, playable rendering, full compute/ray-tracing support, or crash-free execution. The dark-world rendering, unsupported compute instructions and device-removal work remain separate compatibility priorities. No title files, derived shaders, screenshots, personal paths or raw telemetry should be committed. See [hardware-benchmark.md](hardware-benchmark.md), [hardware-validation-build.md](hardware-validation-build.md), [performance-regression.md](performance-regression.md) and [asset-policy.md](asset-policy.md).

## Execution order

Begin with workflows 1 and 2. Then 3 and 4, then 5 and 6, then 7 and 8, followed by 9. A physical V3 baseline can be captured independently when the user is ready. Do not merge into main or submit upstream without separate authorization.
