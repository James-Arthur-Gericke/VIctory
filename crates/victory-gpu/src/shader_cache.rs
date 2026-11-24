//! Translated shaders kept on disk (decision 0003): under the configured
//! cache folder, keyed by the container's content and by the VIctory build
//! that translated it (the BLAKE3 of our executable), so a rebuilt
//! translator never serves an old translation. Entries go through
//! `victory-pipeline`'s content-addressed cache, which writes them
//! atomically; an entry that does not read back is translated again.
//!
//! The entry is our own encoding of [`HostShader`]: a field added to it
//! must be added to `encode` and `decode` too (entries of older builds
//! are ignored anyway).

use std::path::PathBuf;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use victory_pipeline::{Cache, Converter};
use victory_shader::emit::{HostShader, StaticSampler, UserData};
use victory_shader::{HwStage, RootType};

static CACHE: OnceLock<Cache> = OnceLock::new();
static HITS: AtomicU64 = AtomicU64::new(0);
static MISSES: AtomicU64 = AtomicU64::new(0);

/// Inclusive phases: cache requests can contain translation and encoding,
/// and first use can contain all the shader phases. Do not sum their times.
#[derive(Clone, Copy)]
pub(crate) enum ProfilePhase {
    FirstUse,
    Translate,
    Encode,
    CacheRequest,
    ReadDecode,
    DriverCreate,
}

#[cfg(any(test, feature = "diagnostics"))]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Sample {
    calls: u64,
    failures: u64,
    total_us: u64,
    max_us: u64,
}

#[cfg(any(test, feature = "diagnostics"))]
impl Sample {
    const EMPTY: Self = Self { calls: 0, failures: 0, total_us: 0, max_us: 0 };

    fn record(&mut self, us: u64, ok: bool) {
        self.calls = self.calls.saturating_add(1);
        self.failures = self.failures.saturating_add(u64::from(!ok));
        self.total_us = self.total_us.saturating_add(us);
        self.max_us = self.max_us.max(us);
    }
}

#[cfg(feature = "diagnostics")]
const PHASE_NAMES: [&str; 6] = [
    "first-use", "translate", "encode", "cache-request-inclusive",
    "cache-read-decode", "driver-create",
];

#[cfg(feature = "diagnostics")]
static PROFILE: std::sync::Mutex<[Sample; PHASE_NAMES.len()]> =
    std::sync::Mutex::new([Sample::EMPTY; PHASE_NAMES.len()]);

#[cfg(feature = "diagnostics")]
fn profiling() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var_os("VICTORY_SHADER_PROFILE").is_some())
}

pub(crate) fn profile<T>(
    phase: ProfilePhase,
    work: impl FnOnce() -> T,
    success: impl FnOnce(&T) -> bool,
) -> T {
    #[cfg(feature = "diagnostics")]
    if profiling() {
        let started = std::time::Instant::now();
        let result = work();
        let us = started.elapsed().as_micros().min(u128::from(u64::MAX)) as u64;
        PROFILE.lock().unwrap_or_else(|e| e.into_inner())[phase as usize]
            .record(us, success(&result));
        return result;
    }
    let _ = (phase, success);
    work()
}

/// Completed calls since the previous report, grouped by phase. Worker
/// times overlap and are cumulative CPU-side elapsed time, not wall time.
#[cfg(feature = "diagnostics")]
pub(crate) fn log_profile() {
    if !profiling() {
        return;
    }
    let samples = std::mem::replace(
        &mut *PROFILE.lock().unwrap_or_else(|e| e.into_inner()),
        [Sample::EMPTY; PHASE_NAMES.len()],
    );
    for (phase, s) in PHASE_NAMES.into_iter().zip(samples) {
        if s.calls != 0 {
            tracing::info!(
                phase,
                calls = s.calls,
                failures = s.failures,
                total_us = s.total_us,
                max_us = s.max_us,
                "shader compilation profile (inclusive worker elapsed time)"
            );
        }
    }
}

/// Keeps translated shaders in `dir` from now on.
pub fn use_shader_cache(dir: PathBuf) {
    match Cache::open(dir) {
        Ok(cache) => {
            let _ = CACHE.set(cache);
        }
        Err(e) => tracing::warn!(error = %e, "no shader cache"),
    }
}

/// Shaders found in the cache and translated since the start.
pub(crate) fn counts() -> (u64, u64) {
    (HITS.load(Ordering::Relaxed), MISSES.load(Ordering::Relaxed))
}

/// What identifies this build: the BLAKE3 of our executable file and of
/// the translation settings it runs with (the loop limit, which a
/// diagnostics build can change at run time).
fn build() -> &'static [u8; 32] {
    static BUILD: OnceLock<[u8; 32]> = OnceLock::new();
    BUILD.get_or_init(|| {
        let exe = std::env::current_exe().and_then(std::fs::read);
        let limit = victory_shader::emit::loop_limit();
        if limit != victory_shader::emit::DEFAULT_LOOP_LIMIT {
            tracing::warn!(
                limit,
                "VICTORY_SHADER_LOOP_LIMIT: translated loops stop sooner"
            );
        }
        match exe {
            Ok(mut bytes) => {
                bytes.extend_from_slice(&limit.to_le_bytes());
                *blake3::hash(&bytes).as_bytes()
            }
            Err(e) => {
                // Without it no entry can be trusted: a fresh key per run.
                tracing::warn!(error = %e, "cannot read our executable; shader cache unused");
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default();
                *blake3::hash(&now.as_nanos().to_le_bytes()).as_bytes()
            }
        }
    })
}

/// The translation of a console shader container, from the cache when
/// there is one.
pub(crate) fn host_shader(
    container: &[u8],
    translate: impl Fn(&[u8]) -> Result<HostShader, String> + Send + Sync,
) -> Result<HostShader, String> {
    match CACHE.get() {
        Some(cache) => cached(cache, build(), container, translate),
        None => profile(ProfilePhase::Translate, || translate(container), Result::is_ok),
    }
}

/// The cache entry's converter: the build and the container in, the
/// encoded translation out. `ran` tells a miss from a hit.
struct Translate<F> {
    translate: F,
    ran: AtomicBool,
}

impl<F: Fn(&[u8]) -> Result<HostShader, String> + Send + Sync> Converter for Translate<F> {
    fn id(&self) -> &'static str {
        "shader.dxil"
    }
    fn version(&self) -> u32 {
        // The build fingerprint in the input does the versioning.
        1
    }
    fn convert(&self, input: &[u8]) -> anyhow::Result<Vec<u8>> {
        self.ran.store(true, Ordering::Relaxed);
        let shader = profile(
            ProfilePhase::Translate,
            || (self.translate)(&input[32..]),
            Result::is_ok,
        ).map_err(anyhow::Error::msg)?;
        Ok(profile(ProfilePhase::Encode, || encode(&shader), |_| true))
    }
}

fn cached(
    cache: &Cache,
    build: &[u8; 32],
    container: &[u8],
    translate: impl Fn(&[u8]) -> Result<HostShader, String> + Send + Sync,
) -> Result<HostShader, String> {
    let input = [&build[..], container].concat();
    let converter = Translate {
        translate,
        ran: AtomicBool::new(false),
    };
    for _ in 0..2 {
        let path = profile(
            ProfilePhase::CacheRequest,
            || cache.get_or_convert(&converter, &input),
            Result::is_ok,
        ).map_err(|e| format!("{e:#}"))?;
        if let Some(shader) = profile(
            ProfilePhase::ReadDecode,
            || crate::io_profile::read(crate::io_profile::Phase::ShaderCacheRead, &path).ok().and_then(|b| {
                let len = b.len() as u64;
                crate::io_profile::measure(
                    crate::io_profile::Phase::ShaderCacheDecode, len,
                    || decode(&b),
                    |r| (if r.is_some() { len } else { 0 }, r.is_some()),
                )
            }),
            Option::is_some,
        ) {
            let (counter, what) = if converter.ran.load(Ordering::Relaxed) {
                (&MISSES, "translated and cached")
            } else {
                (&HITS, "from the cache")
            };
            counter.fetch_add(1, Ordering::Relaxed);
            tracing::debug!(path = %path.display(), "shader {what}");
            return Ok(shader);
        }
        tracing::debug!(path = %path.display(), "unreadable shader cache entry; translating again");
        let _ = std::fs::remove_file(&path);
    }
    MISSES.fetch_add(1, Ordering::Relaxed);
    profile(ProfilePhase::Translate, || (converter.translate)(container), Result::is_ok)
}

const MAGIC: &[u8; 4] = b"VSH1";
const STAGES: [HwStage; 8] = [
    HwStage::Ls,
    HwStage::Hs,
    HwStage::Es,
    HwStage::Gs,
    HwStage::Vs,
    HwStage::Ps,
    HwStage::Ms,
    HwStage::Cs,
];

fn root_code(r: RootType) -> u32 {
    match r {
        RootType::Constants => 0,
        RootType::Descriptor => 1,
        RootType::Table => 2,
        RootType::ImmediateSampler => 3,
        RootType::ResourceHeap => 4,
        RootType::SamplerHeap => 5,
        RootType::Other(x) => 6 + x,
    }
}

fn root_type(code: u32) -> RootType {
    match code {
        0 => RootType::Constants,
        1 => RootType::Descriptor,
        2 => RootType::Table,
        3 => RootType::ImmediateSampler,
        4 => RootType::ResourceHeap,
        5 => RootType::SamplerHeap,
        x => RootType::Other(x - 6),
    }
}

/// Little-endian words and length-prefixed lists.
fn encode(s: &HostShader) -> Vec<u8> {
    let mut out = MAGIC.to_vec();
    let word = |out: &mut Vec<u8>, v: u32| out.extend(v.to_le_bytes());
    let stage = STAGES.iter().position(|&x| x == s.stage).unwrap_or(0) as u32;
    word(&mut out, stage);
    word(&mut out, s.dxil.len() as u32);
    out.extend(&s.dxil);
    word(&mut out, s.user_data.len() as u32);
    for u in &s.user_data {
        for v in [u.index, u32::from(u.slot), root_code(u.root), u.dword] {
            word(&mut out, v);
        }
    }
    word(&mut out, s.samplers.len() as u32);
    for sampler in &s.samplers {
        for &v in sampler {
            word(&mut out, v);
        }
    }
    word(&mut out, s.static_samplers.len() as u32);
    for t in &s.static_samplers {
        let [u, v, w] = t.address;
        let words = [
            t.filter,
            u,
            v,
            w,
            t.mip_lod_bias.to_bits(),
            t.max_anisotropy,
            t.comparison,
            t.border,
            t.min_lod.to_bits(),
            t.max_lod.to_bits(),
        ];
        for v in words {
            word(&mut out, v);
        }
    }
    for slots in [&s.root_cbvs, &s.root_srvs] {
        word(&mut out, slots.len() as u32);
        out.extend(slots);
    }
    out
}

fn decode(bytes: &[u8]) -> Option<HostShader> {
    struct Reader<'a>(&'a [u8]);
    impl<'a> Reader<'a> {
        fn take(&mut self, n: usize) -> Option<&'a [u8]> {
            let (head, rest) = self.0.split_at_checked(n)?;
            self.0 = rest;
            Some(head)
        }
        fn word(&mut self) -> Option<u32> {
            Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
        }
        fn list(&mut self) -> Option<Vec<u8>> {
            let n = self.word()? as usize;
            Some(self.take(n)?.to_vec())
        }
    }
    let mut r = Reader(bytes);
    if r.take(4)? != MAGIC {
        return None;
    }
    let stage = *STAGES.get(r.word()? as usize)?;
    let dxil = r.list()?;
    let n = r.word()? as usize;
    // The host binds user data as D3D12 root constants (at most 64
    // DWORDs in an entire root signature). Reject corrupt cache metadata
    // before user_data_dwords rounds the index or the host uses it.
    if n > 64 {
        return None;
    }
    let mut user_data = Vec::with_capacity(n);
    let mut seen = 0u64;
    for _ in 0..n {
        let index = r.word()?;
        let bit = 1u64.checked_shl(index)?;
        if seen & bit != 0 {
            return None;
        }
        seen |= bit;
        user_data.push(UserData {
            index,
            slot: u8::try_from(r.word()?).ok()?,
            root: root_type(r.word()?),
            dword: r.word()?,
        });
    }
    let n = r.word()? as usize;
    let mut samplers = Vec::with_capacity(n.min(256));
    for _ in 0..n {
        samplers.push([r.word()?, r.word()?, r.word()?, r.word()?]);
    }
    let n = r.word()? as usize;
    let mut static_samplers = Vec::with_capacity(n.min(256));
    for _ in 0..n {
        static_samplers.push(StaticSampler {
            filter: r.word()?,
            address: [r.word()?, r.word()?, r.word()?],
            mip_lod_bias: f32::from_bits(r.word()?),
            max_anisotropy: r.word()?,
            comparison: r.word()?,
            border: r.word()?,
            min_lod: f32::from_bits(r.word()?),
            max_lod: f32::from_bits(r.word()?),
        });
    }
    let root_cbvs = r.list()?;
    let root_srvs = r.list()?;
    r.0.is_empty().then_some(HostShader {
        stage,
        dxil,
        user_data,
        samplers,
        static_samplers,
        root_cbvs,
        root_srvs,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shader() -> HostShader {
        HostShader {
            stage: HwStage::Ps,
            dxil: b"DXBC and the rest".to_vec(),
            user_data: vec![UserData {
                index: 8,
                slot: 1,
                root: RootType::Table,
                dword: 0,
            }],
            samplers: vec![[0x400, 0xc0_0000, 0x18f0_0000, 0]],
            static_samplers: vec![StaticSampler::from_words([
                0x400,
                0xc0_0000,
                0x18f0_0000,
                0,
            ])],
            root_cbvs: vec![2],
            root_srvs: vec![0, 3],
        }
    }

    #[test]
    fn profile_samples_count_failures_and_saturate() {
        let mut s = Sample::EMPTY;
        s.record(4, true);
        s.record(10, false);
        s.record(0, true);
        assert_eq!(s, Sample { calls: 3, failures: 1, total_us: 14, max_us: 10 });
        s.record(u64::MAX, false);
        assert_eq!(s.total_us, u64::MAX);
        assert_eq!(s.max_us, u64::MAX);
        let previous = std::mem::replace(&mut s, Sample::EMPTY);
        assert_eq!(previous.calls, 4);
        assert_eq!(previous.failures, 2);
        assert_eq!(s, Sample::default());

        // The wrapper must preserve success/failure values.
        assert_eq!(profile(ProfilePhase::Translate, || Ok::<_, &str>(7), Result::is_ok), Ok(7));
        assert_eq!(profile(ProfilePhase::Translate, || Err::<(), _>("unsupported"), Result::is_ok), Err("unsupported"));
    }

    #[test]
    fn translations_come_back_from_the_cache() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::open(dir.path()).unwrap();
        let build = [7u8; 32];
        let container = b"a console container".as_slice();
        let runs = AtomicU64::new(0);
        let translate = |_: &[u8]| {
            runs.fetch_add(1, Ordering::Relaxed);
            Ok(shader())
        };
        assert_eq!(cached(&cache, &build, container, translate), Ok(shader()));
        assert_eq!(cached(&cache, &build, container, translate), Ok(shader()));
        assert_eq!(runs.load(Ordering::Relaxed), 1, "the second came from disk");

        // Another build translates again.
        assert_eq!(cached(&cache, &[8; 32], container, translate), Ok(shader()));
        assert_eq!(runs.load(Ordering::Relaxed), 2);

        // A damaged entry is a miss, translated and stored again.
        for e in walk(dir.path()) {
            std::fs::write(e, b"VSH1 broken").unwrap();
        }
        assert_eq!(cached(&cache, &build, container, translate), Ok(shader()));
        assert_eq!(runs.load(Ordering::Relaxed), 3);
        assert_eq!(cached(&cache, &build, container, translate), Ok(shader()));
        assert_eq!(runs.load(Ordering::Relaxed), 3);

        // Failures are not stored.
        let fail = |_: &[u8]| Err::<HostShader, _>("unsupported".to_owned());
        assert!(cached(&cache, &build, b"other", fail).is_err());
    }

    fn walk(dir: &std::path::Path) -> Vec<PathBuf> {
        let mut files = Vec::new();
        for e in std::fs::read_dir(dir).unwrap().flatten() {
            if e.path().is_dir() {
                files.extend(walk(&e.path()));
            } else {
                files.push(e.path());
            }
        }
        files
    }

    #[test]
    fn rejects_out_of_range_or_duplicate_cached_user_data() {
        let mut s = shader();
        s.user_data[0].index = 63;
        assert_eq!(decode(&encode(&s)), Some(s.clone()));
        for index in [64, u32::MAX - 1, u32::MAX] {
            s.user_data[0].index = index;
            assert_eq!(decode(&encode(&s)), None);
        }
        s.user_data[0].index = 0;
        s.user_data.push(s.user_data[0]);
        assert_eq!(decode(&encode(&s)), None);

        s.user_data = (0..64)
            .map(|index| UserData {
                index,
                ..s.user_data[0]
            })
            .collect();
        assert_eq!(decode(&encode(&s)), Some(s.clone()));
        s.user_data.push(s.user_data[0]);
        assert_eq!(decode(&encode(&s)), None);
    }

    #[test]
    fn invalid_cached_index_is_retranslated() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::open(dir.path()).unwrap();
        let build = [9u8; 32];
        let container = b"synthetic container".as_slice();
        let runs = AtomicU64::new(0);
        let translate = |_: &[u8]| {
            runs.fetch_add(1, Ordering::Relaxed);
            Ok(shader())
        };

        assert_eq!(cached(&cache, &build, container, translate), Ok(shader()));
        let mut invalid = shader();
        invalid.user_data[0].index = u32::MAX;
        let files = walk(dir.path());
        assert!(!files.is_empty());
        for path in files {
            std::fs::write(path, encode(&invalid)).unwrap();
        }

        assert_eq!(cached(&cache, &build, container, translate), Ok(shader()));
        assert_eq!(runs.load(Ordering::Relaxed), 2);
        assert_eq!(cached(&cache, &build, container, translate), Ok(shader()));
        assert_eq!(runs.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn entries_round_trip_and_reject_damage() {
        let bytes = encode(&shader());
        assert_eq!(decode(&bytes), Some(shader()));
        assert_eq!(decode(&bytes[..bytes.len() - 1]), None);
        assert_eq!(decode(&[bytes.as_slice(), &[0]].concat()), None);
        assert_eq!(decode(b"VSH0"), None);
    }
}
