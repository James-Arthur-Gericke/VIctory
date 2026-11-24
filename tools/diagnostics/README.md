# Diagnostic comparison helper

AI-assisted development. This helper compares numeric summary samples from two authorized VIctory diagnostic runs. It does not run the title or change the runtime. Requires a POSIX shell and awk (e.g. Git Bash on Windows), and UTF-8 logs.

Run synthetic checks: `sh tools/diagnostics/test-compare-logs.sh`.

Compare: `sh tools/diagnostics/compare-logs.sh baseline.log candidate.log 1 10 1 10`.

The four numbers select inclusive, one-based logged sample windows. Choose equivalent scenes, hardware, drivers, cache conditions and settings. Record each build SHA independently. Legacy logs sample roughly one second of measurements every five seconds. When every selected summary in both runs includes a positive sample_frames field (see the fork's diagnostics patch), frame time, draw and drop rates are weighted by frame counts and FPS is estimated from total frames divided by estimated elapsed time. Pending pipelines and listed reason details remain sample means. If either window lacks counts, both use unweighted sample means. None of these are necessarily whole-run means. The top-40 reason cap means an absent reason is not zero. Joint shader labels must not be counted as independent failures. Raw lines and unknown labels are not reproduced; inspect output before sharing. Keep proprietary files and raw logs outside the repository in accordance with docs/asset-policy.md.

Validation: 14 synthetic checks passed locally on Linux. Windows/GPU/title testing and upstream Rust asset-policy execution have not been performed. Lower frame time or fewer dropped draws does not prove correct rendering.

Upstream format: crates/victory-gpu/src/host.rs and crates/victory-gpu/src/pipeline/make.rs at ffe310e. Context: upstream issues #293 and #732. Do not submit upstream while external PRs are paused.
