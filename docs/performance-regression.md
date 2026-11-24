# Automated present-interval regression gate

This is a follow-up to the local PresentMon comparison protocol. It requires at
least three independently captured A/B pairs and reports the median of paired
percentage regressions for present FPS, P95 and P99 interval. By default a
median FPS loss above 5%, P95 rise above 10%, or P99 rise above 15% fails.
Thresholds are initial engineering tolerances, not statistical confidence
limits. Each capture needs 1000 intervals by default and paired durations
must agree within 10% of baseline. Both conditions are configurable.

Create a JSON manifest outside the repository with Comparable set to true only
after checking the same hardware, driver, scene, settings, cache state, and
visual correctness. Pairs is an array of at least three objects. Each has
Baseline and Candidate objects, with Path (relative to the manifest or
absolute), ProcessId, SwapChain, Skip (at least one), Count (zero for remaining).
For example one pair is:

    {"Baseline":{"Path":"a1.csv","ProcessId":1234,"SwapChain":"0xAB","Skip":1,"Count":0},"Candidate":{"Path":"b1.csv","ProcessId":5678,"SwapChain":"0xCD","Skip":1,"Count":0}}

Use different files for every run. Duplicate paths and identical file hashes
are rejected. Alternate run order. Keep capture and manifest files local.
Invoke with PowerShell 7:

    pwsh -NoProfile -File tools/benchmark/Test-PresentRegression.ps1 -Manifest C:\Benchmarks\pairs.json

JSON output includes all pair deltas, median regressions and thresholds.
Exit 0 means within configured tolerances; 1 means a regression; 2 means input
was invalid or not comparable. This does not prove a statistically significant
change, rendered FPS, scene correctness, or GPU utilization. A black scene
presenting faster is not an improvement. No real capture is run in hosted CI;
synthetic tests verify scoring only. At low present rates, longer captures
are needed or a deliberately lower sample minimum with weaker tail evidence.
