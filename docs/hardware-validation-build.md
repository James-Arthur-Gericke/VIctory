# Experimental hardware validation build

Integration V3 combines the validated V2 tree with PRs #28–37 and the
standalone diagnostic comparator. The hosted CI check job must succeed
before a separate Windows job builds release and diagnostics binaries with
the locked dependency graph and pinned toolchain. The build job checks out
the exact pull request head and runs only CLI --version and --help.
No title is downloaded or executed; no self-hosted runner is used.

Download the workflow artifact named victory-hardware-<run>-<attempt>.
It contains two VIctory executables, LICENSE and build-manifest.json with
source identity, toolchain, size and SHA256 for each executable. Artifacts
expire after seven days. Check the workflow source and manifest before
running any executable; compare Get-FileHash -Algorithm SHA256 to the manifest.
The corresponding source is the commit linked in the manifest. No game
data or derived files are included or committed. Benchmark and comparator
scripts are available separately in that exact source tree.

For local comparison use the same machine, driver, settings and repeatable
scene. Keep separate data/cache directories outside the source tree; back
up existing saves and configuration. Start with the diagnostics build using
the documented WARP software-adapter mode, then review logs before attempting
hardware tests. The README warns that world rendering can hang a real GPU
and reset its driver. Do not use unattended hardware execution. Compare
like profiles across baseline and candidate. The A/B protocol is in
docs/hardware-benchmark.md; regression gates are in docs/performance-regression.md.

The diagnostics build supports VICTORY_GPU_RESIDENCY=1 (DXGI memory budget,
not physical free VRAM) and VICTORY_SHADER_PROFILE=1 (inclusive worker
elapsed times, not additive wall time). Compare equivalent diagnostics
settings. These counters follow the existing frame-sample cadence and may
not report while frames are stalled. See tools/diagnostics/README.md for the
frame-weighted log comparator.

A passing CI build is not evidence of playable rendering or improved FPS.
