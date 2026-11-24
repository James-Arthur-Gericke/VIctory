# Combined hardware reporting (V3.1 workflow 7)

PowerShell 7. Read local captures from PRs 40, 42 and 44 plus V3 diagnostics log and PresentMon CSV; independent of their implementations. No title execution, no hardware access. Create a JSON manifest outside the repository, for example:

    {
      "schema":"victory.hardware.manifest.v1",
      "runId":"baseline-1",
      "buildSha":"<40-character git commit>",
      "conditionsKey":"same-machine-driver-scene-profile-cache-instrumentation",
      "processId":1234,
      "processStartUtcTicks":638000000000000000,
      "windowStartUtc":"2026-01-01T00:00:00Z",
      "windowEndUtc":"2026-01-01T00:01:00Z",
      "windowAligned":true,
      "visualCorrect":true,
      "deviceRemoved":false,
      "cpu":"cpu.jsonl","ram":"ram.jsonl","storage":"storage.jsonl",
      "diskInstance":"0 C:","victoryLog":"victory.log",
      "presentCsv":"present.csv","present":{"swapChain":"0xAB","skip":1,"count":0},
      "gpuAdapter":"local-adapter-id","gpu":"gpu.jsonl"
    }

Use actual run identity and UTC bounds. The operator must confirm the log belongs to this process, the selected PresentMon intervals align with this window (duration cross-check is not proof), visual correctness and device removal status. Conditions key must identify all matched hardware, driver, scene, settings, cache state, capture settings, adapter, disk and executable profile; record exact details locally. Use unique run IDs. Omit absent capture fields. Optional GPU JSONL is a normalized external vendor export (schema victory.gpu.external.v1, utc offset timestamp, adapter matching gpuAdapter, optional busyPercent/clockMHz/temperatureC/powerW); no vendor adapter or sensor collection implemented. Do not invent missing readings. The process identity is checked on CPU/RAM/storage streams. Disk instance must be selected explicitly.

    ./tools/diagnostics/New-HardwareReport.ps1 -Manifest C:\Benchmarks\run.json > C:\Benchmarks\report.json

Use -HumanReadable for a text summary. JSON schema victory.hardware.report.v1 contains value/unit/samples for each metric, null for unavailable, sample counts per stream, and nearest-neighbor rows at CPU timestamps (default maximum absolute skew 1500 ms). Reused nearest observations are not independent. Stream-level averages are sample means, not time-weighted, and physical disk counters are machine-wide. Frame summary averages use sample_frames weights or return null if missing. GPU wait is not utilization, local DXGI budget is not physical capacity, and present FPS is not displayed/game FPS. Shader translate metrics are inclusive worker elapsed time per call. Log windows use emission timestamps, not exact interval boundaries. No interpolation, automatic bottleneck classification or full vendor sensor integration. Keep raw logs and reports outside Git. Synthetic tests exercise alignment, missing data, PID validation, frame/VRAM parsing and CLI smoke. Transfer and offline scaling benchmarks are separate workloads and must not be aligned as gameplay samples.
