//! Opt-in aggregate asset I/O telemetry. No file paths, data or labels from
//! the title. Timings are inclusive worker elapsed time, not disk busy time.
use std::time::Instant;

#[derive(Clone, Copy)]
pub enum Phase {
    StorageRequest,
    StorageFileRead,
    Zlib,
    Bcpack,
    ShaderCacheRead,
    ShaderCacheDecode,
    PipelineCacheRead,
}

#[cfg(any(test, feature = "diagnostics"))]
#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
struct Totals {
    calls: u64,
    failures: u64,
    requested_bytes: u64,
    completed_bytes: u64,
    total_us: u64,
    max_us: u64,
}

#[cfg(any(test, feature = "diagnostics"))]
impl Totals {
    fn add(&mut self, requested: u64, completed: u64, ok: bool, us: u64) {
        self.calls = self.calls.saturating_add(1);
        self.failures = self.failures.saturating_add(u64::from(!ok));
        self.requested_bytes = self.requested_bytes.saturating_add(requested);
        self.completed_bytes = self.completed_bytes.saturating_add(completed);
        self.total_us = self.total_us.saturating_add(us);
        self.max_us = self.max_us.max(us);
    }
}

#[cfg(feature = "diagnostics")]
const NAMES: [&str; 7] = [
    "storage-request-inclusive", "storage-file-read", "zlib", "bcpack",
    "shader-cache-read", "shader-cache-decode", "pipeline-cache-read",
];

#[cfg(feature = "diagnostics")]
#[derive(Default)]
struct Bucket {
    totals: Totals,
    last: Option<Instant>,
}

#[cfg(feature = "diagnostics")]
static BUCKETS: std::sync::OnceLock<std::sync::Mutex<[Bucket; NAMES.len()]>> =
    std::sync::OnceLock::new();

/// None in release or if instrumentation is disabled. No per-call clock
/// query, mutex or logging in that case.
pub fn start() -> Option<Instant> {
    #[cfg(feature = "diagnostics")]
    {
        static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        if *ENABLED.get_or_init(|| std::env::var_os("VICTORY_ASSET_IO_PROFILE").is_some()) {
            return Some(Instant::now());
        }
    }
    None
}

/// Report cumulative totals at most once per second per active phase
/// (including the first completion); never depend on a presented frame.
/// A final quiet tail may not be reported. Do not sum nested phases.
pub fn finish(
    started: Option<Instant>,
    phase: Phase,
    requested: u64,
    completed: u64,
    ok: bool,
) {
    #[cfg(feature = "diagnostics")]
    if let Some(started) = started {
        let now = Instant::now();
        let us = now.duration_since(started).as_micros().min(u128::from(u64::MAX)) as u64;
        let report = {
            let mut buckets = BUCKETS
                .get_or_init(|| std::sync::Mutex::new(std::array::from_fn(|_| Bucket::default())))
                .lock().unwrap_or_else(|e| e.into_inner());
            let bucket = &mut buckets[phase as usize];
            bucket.totals.add(requested, completed, ok, us);
            if bucket.last.is_none_or(|last| now.saturating_duration_since(last).as_secs() >= 1) {
                bucket.last = Some(now);
                Some(bucket.totals)
            } else {
                None
            }
        };
        if let Some(s) = report {
            tracing::info!(
                phase = NAMES[phase as usize],
                calls = s.calls, failures = s.failures,
                requested_bytes = s.requested_bytes, completed_bytes = s.completed_bytes,
                total_us = s.total_us, max_us = s.max_us,
                "asset io cumulative (worker elapsed)"
            );
        }
        return;
    }
    let _ = (started, phase, requested, completed, ok);
}

/// Preserve the result verbatim; classify it only when profiling is on.
pub fn measure<T>(
    phase: Phase,
    requested: u64,
    work: impl FnOnce() -> T,
    classify: impl FnOnce(&T) -> (u64, bool),
) -> T {
    let started = start();
    let result = work();
    if started.is_some() {
        let (completed, ok) = classify(&result);
        finish(started, phase, requested, completed, ok);
    }
    result
}

/// File read bytes count only successful reads. A failed read may have
/// made partial progress internally, which std::fs::read does not expose.
pub fn read(phase: Phase, path: impl AsRef<std::path::Path>) -> std::io::Result<Vec<u8>> {
    measure(phase, 0, || std::fs::read(path), |r| {
        (r.as_ref().map_or(0, |b| b.len() as u64), r.is_ok())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn totals_keep_partial_bytes_errors_and_saturate() {
        let mut t = Totals::default();
        t.add(100, 100, true, 7);
        t.add(100, 30, false, 11);
        t.add(0, 0, true, 0);
        assert_eq!(t, Totals {
            calls: 3, failures: 1, requested_bytes: 200,
            completed_bytes: 130, total_us: 18, max_us: 11,
        });
        t.add(u64::MAX, u64::MAX, false, u64::MAX);
        assert_eq!(t.requested_bytes, u64::MAX);
        assert_eq!(t.completed_bytes, u64::MAX);
        assert_eq!(t.total_us, u64::MAX);
        assert_eq!(t.max_us, u64::MAX);
    }

    #[test]
    fn read_and_measure_preserve_success_and_failure() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("synthetic");
        std::fs::write(&path, b"synthetic bytes").unwrap();
        assert_eq!(read(Phase::ShaderCacheRead, &path).unwrap(), b"synthetic bytes");
        let absent = tmp.path().join("absent");
        assert_eq!(read(Phase::PipelineCacheRead, absent).unwrap_err().kind(), std::io::ErrorKind::NotFound);
        let value = measure(Phase::Zlib, 1, || Err::<usize, _>(17), |r| {
            (r.as_ref().copied().unwrap_or(0) as u64, r.is_ok())
        });
        assert_eq!(value, Err(17));
    }
}
