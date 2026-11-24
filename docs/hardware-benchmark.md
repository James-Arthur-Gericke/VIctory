# Hardware A/B benchmark protocol

Use the same legally supplied local test data, Windows build, CPU/GPU, driver,
resolution, settings, scene and input sequence for baseline and candidate.
Record both git commit IDs, build mode, driver, GPU model, CPU, RAM, resolution,
cache state and diagnostics environment variables in your local run notes.
Use separate external cache directories for cold-cache runs; warm each build
separately for warm-cache runs. Do not delete a user's existing cache.
Restart between runs and alternate A/B order; perform at least three repeats
per condition. Compare identical scene windows and approximately equal durations.
A black scene or a higher dropped-draw count is not a successful speedup.

## Capture

Use a compatible PresentMon console build with the legacy interval columns
(ProcessID, SwapChainAddress, MsBetweenPresents). See its
[console documentation](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md)
for the version-specific options, including --v1_metrics.

Example (run PresentMon while the intended VIctory process is running;
replace the example PID and output path; stop capture after the selected scene):

    PresentMon.exe --process_id 1234 --v1_metrics --output_file C:\Benchmarks\baseline.csv

Capture candidate separately. Record the correct process ID and swap chain
for each capture; a recreated swap chain must be measured as a separate window.
Do not use exclude-dropped when comparing application present cadence.
Capture files and run notes must stay outside the repository; do not commit
raw telemetry, screenshots, game files or derived assets.

## Compare

From the repository root in PowerShell, with the paths and identities from
your captures (the numbers below are examples):

    ./tools/benchmark/Compare-Presents.ps1 -Baseline C:\Benchmarks\baseline.csv -Candidate C:\Benchmarks\candidate.csv -BaselineProcessId 1234 -CandidateProcessId 5678 -BaselineSwapChain 0xAB -CandidateSwapChain 0xCD -BaselineSkip 1 -CandidateSkip 1

Skip at least one row from each selected swap chain because the first interval
may not be fully within the capture. Increase Skip to exclude warmup, and
optionally specify BaselineCount and CandidateCount to select a contiguous
window; zero means all remaining rows. Invalid or missing intervals in the
window are errors rather than silently removed. The tool reports actual
interval count and total duration, aggregate present FPS (count / duration),
mean, nearest-rank P50/P95/P99 and maximum interval, plus candidate minus
baseline. Higher present FPS and lower frame intervals are generally better,
but presents may be dropped, duplicated, or contain only UI. This is not a
displayed FPS, game simulation FPS, or input latency measurement. Tail metrics
need large samples; at very low FPS use longer captures.

For each run also retain local VIctory frame summaries (draws, drops, CPU
preparation, GPU wait and shader/pipeline cache activity), and optionally a
separate vendor monitoring capture for GPU utilization, dedicated/shared
memory and clocks. This tool does not collect or infer those measurements.
Validate scene correctness before interpreting speed. Synthetic CI only checks
the interval statistics, not hardware performance.
