# Experimental hardware validation build

This branch starts from the CI-validated Integration V2 commit, not from the
four later standalone GPU patches. The hosted CI check job must succeed
before a separate Windows job builds the release and diagnostics binaries
with the locked dependency graph and pinned toolchain. The build job checks
out the exact pull request head and runs only CLI --version and --help.
No title is downloaded or executed, no self-hosted runner is used.

Download the workflow artifact named victory-hardware-<run>-<attempt>.
It contains two VIctory executables, LICENSE and build-manifest.json with
source identity, toolchain, size and SHA256 for each executable. Artifacts
expire after seven days. Check the workflow source and manifest before
running any executable; compare Get-FileHash -Algorithm SHA256 to the manifest.
The corresponding source is the commit linked in the manifest. No game
data or derived files are included or committed.

For later local comparison use the same machine, driver, settings and
repeatable scene. Keep separate data/cache directories outside the source
tree; back up existing saves and configuration. Start with the diagnostics
build using the documented WARP software-adapter mode, then review logs
and smoke results before attempting hardware tests. The project README warns
that world rendering can hang a real GPU and reset its driver. Do not use
unattended hardware execution. No automatic execution or machine access is
part of this workflow. The release/diagnostics builds differ in features:
compare like profiles across baseline and candidate. The A/B protocol is in
docs/hardware-benchmark.md. Later residency and shader profiling patches
require a new combined integration before their new flags are available.

A passing CI build is not evidence of playable rendering or improved FPS.
