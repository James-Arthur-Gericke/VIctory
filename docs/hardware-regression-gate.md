# Hardware regression gate (V3.1 workflow 8)

Independent of the combined report implementation. Consumes the documented victory.hardware.report.v1 schema (PR #46), not raw hardware access. Keep all reports and manifests outside the repository. Minimum three independent baseline/candidate pairs, same conditions key, disk, adapter, skew, and two distinct fixed build identities. Operator attests equivalent scene, driver, cache, profile, settings and instrumentation. Unique run IDs, file paths and hashes guard against obvious duplication, not prove independent experiments.

Example manifest:

    {
      "schema":"victory.hardware.regression.manifest.v1",
      "comparable":true,
      "thresholds":{"ramPrivatePeakBytes":10,"cpuPrepareMs":10,"diskReadLatencyMs":15},
      "pairs":[
        {"baseline":{"report":"a1.json"},"candidate":{"report":"b1.json"}},
        {"baseline":{"report":"a2.json"},"candidate":{"report":"b2.json"}},
        {"baseline":{"report":"a3.json"},"candidate":{"report":"b3.json"}}
      ]
    }

    ./tools/benchmark/Test-HardwareRegression.ps1 -Manifest C:\Benchmarks\compare.json

Default limits (provisional, not measured hardware targets): median FPS loss 5%, P95 increase 10%, P99 increase 15%; any paired increase in dropped draws per frame fails (absolute tolerance zero). All must have enough samples: 1000 present intervals, at least three frame samples. Additional explicit metrics: cpuPrepareMs, gpuWaitMs, shaderTranslateMeanMs, ramPrivatePeakBytes, ramWorkingSetPeakBytes, gpuLocalUsagePeakBytes, diskReadLatencyMs, transferUploadMiBps. Optional thresholds are percent increases except transfer throughput loss; dropped-draw threshold is absolute. Each additional metric requires at least three samples per run. Relative zero baselines, missing metrics, wrong units and inadequate samples fail closed rather than becoming zero. Paired duration tolerance defaults to 10%. These sample-count checks do not prove uniform coverage; inspect the source reports.

Correctness first: any run with visualCorrect=false or deviceRemoved=true fails regardless of FPS; missing confirmation is invalid. Positive dropped-draw tolerance is an explicit override. CPU/GPU utilization or read throughput alone is not directional evidence of regression and is excluded. Compare RAM peaks only over matched sampling and scene windows; report sample means are not time-weighted.

Optional companion transfer workload: add a threshold transferUploadMiBps and top-level transfer object with regionBytes (e.g. 262144), pooled (boolean), adapterIdentity (vendor:device:LUID as emitted by PR #43). Add transferLog path under each baseline/candidate entry, from a separate supervised physical-adapter benchmark of that exact build and condition. Each log must have at least three distinct verified repeats of the selected mode and matching physical adapter, no WARP. Compare median upload-fence throughput of each log across paired reports. The operator confirms transfer logs belong to the corresponding builds; timing is not raw PCIe bandwidth. Do not conflate this synthetic workload with gameplay.

Exit 0 within limits; 1 regression or correctness failure; 2 invalid/insufficient input. Synthetic tests cover improvements, regressions, outliers, dropped draws, correctness, missing values, conditions, duplicate identity, transfer parsing and CLI exit codes. No claim of hardware validation or speedup; no automated title execution.
