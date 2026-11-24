//! Standalone synthetic buffer transfers, no title or runtime resource reuse.
use super::*;
use std::time::{Duration, Instant};

const REGIONS: usize = 4;
const MAX_REGION: usize = 16 << 20;

fn layout(bytes: usize, pooled: bool) -> Result<Vec<(usize, usize)>, String> {
    if !(512..=MAX_REGION).contains(&bytes) || !bytes.is_multiple_of(512) {
        return Err("region size must be a multiple of 512, up to 16 MiB".into());
    }
    Ok((0..REGIONS)
        .map(|i| if pooled { (0, i * bytes) } else { (i, 0) })
        .collect())
}

fn pattern(i: usize) -> u8 {
    (i.wrapping_mul(131) ^ (i >> 8) ^ (i >> 17)) as u8
}

fn fence_done(completed: u64, expected: u64) -> Result<bool, String> {
    if completed == u64::MAX {
        Err("device removed (fence sentinel)".into())
    } else {
        Ok(completed >= expected)
    }
}

fn submit(
    dev: &ID3D12Device,
    queue: &ID3D12CommandQueue,
    list: &ID3D12CommandList,
    fence: &ID3D12Fence,
    value: u64,
    timeout: Duration,
) -> Result<Duration, String> {
    let started = Instant::now();
    // SAFETY: the caller owns a closed list and keeps every resource
    // alive through confirmed completion or process termination.
    unsafe {
        queue.ExecuteCommandLists(&[Some(list.clone())]);
        queue.Signal(fence, value).map_err(err)?;
        loop {
            dev.GetDeviceRemovedReason().map_err(err)?;
            if fence_done(fence.GetCompletedValue(), value)? {
                return Ok(started.elapsed());
            }
            if started.elapsed() >= timeout {
                return Err("transfer fence timeout; completion not confirmed".into());
            }
            std::thread::sleep(Duration::from_micros(100));
        }
    }
}

fn buffer(
    dev: &ID3D12Device,
    heap: D3D12_HEAP_TYPE,
    bytes: usize,
    state: D3D12_RESOURCE_STATES,
) -> Result<ID3D12Resource, String> {
    let mut result = None;
    // SAFETY: valid bounded buffer descriptor and output pointer.
    unsafe {
        dev.CreateCommittedResource(
            &D3D12_HEAP_PROPERTIES {
                Type: heap,
                CreationNodeMask: 1,
                VisibleNodeMask: 1,
                ..Default::default()
            },
            D3D12_HEAP_FLAG_NONE,
            &D3D12_RESOURCE_DESC {
                Dimension: D3D12_RESOURCE_DIMENSION_BUFFER,
                Width: bytes as u64,
                Height: 1,
                DepthOrArraySize: 1,
                MipLevels: 1,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Layout: D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
                ..Default::default()
            },
            state,
            None,
            &mut result,
        ).map_err(err)?;
    }
    result.ok_or_else(|| "no buffer".into())
}

pub struct Sample {
    pub bytes: usize,
    pub allocation_ms: f64,
    pub staging_ms: f64,
    pub upload_ms: f64,
    pub readback_ms: f64,
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn sample(dev: &ID3D12Device, bytes: usize, pooled: bool) -> Result<Sample, String> {
    let regions = layout(bytes, pooled)?;
    let total = bytes * REGIONS;
    let source: Vec<u8> = (0..total).map(pattern).collect();
    let allocation = Instant::now();
    let mut uploads = Vec::new();
    for _ in 0..if pooled { 1 } else { REGIONS } {
        uploads.push(buffer(
            dev, D3D12_HEAP_TYPE_UPLOAD, if pooled { total } else { bytes },
            D3D12_RESOURCE_STATE_GENERIC_READ,
        )?);
    }
    let dest = buffer(dev, D3D12_HEAP_TYPE_DEFAULT, total, D3D12_RESOURCE_STATE_COMMON)?;
    let back = buffer(dev, D3D12_HEAP_TYPE_READBACK, total, D3D12_RESOURCE_STATE_COPY_DEST)?;
    let allocation_ms = ms(allocation.elapsed());
    let staging = Instant::now();
    // SAFETY: each mapped region is within its allocation, disjoint,
    // and no GPU work has been submitted yet.
    unsafe {
        for (i, &(which, offset)) in regions.iter().enumerate() {
            let mut data = std::ptr::null_mut();
            uploads[which].Map(0, Some(&D3D12_RANGE { Begin: 0, End: 0 }), Some(&mut data)).map_err(err)?;
            if data.is_null() {
                uploads[which].Unmap(0, None);
                return Err("null upload mapping".into());
            }
            std::ptr::copy_nonoverlapping(source.as_ptr().add(i * bytes), data.cast::<u8>().add(offset), bytes);
            uploads[which].Unmap(0, Some(&D3D12_RANGE { Begin: offset, End: offset + bytes }));
        }
    }
    let staging_ms = ms(staging.elapsed());
    // SAFETY: independent queue, allocators and command lists; resources
    // remain owned until both submissions have confirmed completion.
    unsafe {
        let queue: ID3D12CommandQueue = dev.CreateCommandQueue(&D3D12_COMMAND_QUEUE_DESC {
            Type: D3D12_COMMAND_LIST_TYPE_DIRECT, ..Default::default()
        }).map_err(err)?;
        let a: ID3D12CommandAllocator = dev.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT).map_err(err)?;
        let b: ID3D12CommandAllocator = dev.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT).map_err(err)?;
        let up: ID3D12GraphicsCommandList = dev.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, &a, None).map_err(err)?;
        let down: ID3D12GraphicsCommandList = dev.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, &b, None).map_err(err)?;
        for (i, &(which, offset)) in regions.iter().enumerate() {
            up.CopyBufferRegion(&dest, (i * bytes) as u64, &uploads[which], offset as u64, bytes as u64);
        }
        up.Close().map_err(err)?;
        // DEFAULT buffer promotes COMMON -> COPY_DEST, decays to COMMON
        // after the first ExecuteCommandLists, then promotes to COPY_SOURCE
        // in the separate readback submission. Upload/readback heaps retain
        // their required GENERIC_READ / COPY_DEST states.
        down.CopyBufferRegion(&back, 0, &dest, 0, total as u64);
        down.Close().map_err(err)?;
        let up_list: ID3D12CommandList = up.cast().map_err(err)?;
        let down_list: ID3D12CommandList = down.cast().map_err(err)?;
        let fence: ID3D12Fence = dev.CreateFence(0, D3D12_FENCE_FLAG_NONE).map_err(err)?;
        let timeout = Duration::from_secs(10);
        let timings = submit(dev, &queue, &up_list, &fence, 1, timeout).and_then(|u| {
            submit(dev, &queue, &down_list, &fence, 2, timeout).map(|d| (u, d))
        });
        let (upload, readback) = match timings {
            Ok(t) => t,
            Err(e) => {
                // Fatal for this standalone benchmark: no retry, reset,
                // map or release of potentially in-flight D3D objects.
                // The CLI exits after returning this error.
                std::mem::forget((dev.clone(), queue, a, b, up, down, up_list, down_list, fence, uploads, dest, back));
                return Err(e);
            }
        };
        let mut ptr = std::ptr::null_mut();
        back.Map(0, Some(&D3D12_RANGE { Begin: 0, End: total }), Some(&mut ptr)).map_err(err)?;
        if ptr.is_null() {
            back.Unmap(0, None);
            return Err("null readback mapping".into());
        }
        let matches = std::slice::from_raw_parts(ptr.cast::<u8>(), total) == source.as_slice();
        back.Unmap(0, Some(&D3D12_RANGE { Begin: 0, End: 0 }));
        if !matches {
            return Err("transfer readback did not match source".into());
        }
        Ok(Sample { bytes: total, allocation_ms, staging_ms, upload_ms: ms(upload), readback_ms: ms(readback) })
    }
}

/// List the same DXGI indices accepted by the transfer benchmark.
pub fn list_adapters() -> Result<(), String> {
    // SAFETY: the factory and adapters are owned COM handles. Only DXGI enumeration
    // and descriptor queries are performed here.
    unsafe {
        let factory: IDXGIFactory4 = CreateDXGIFactory2(DXGI_CREATE_FACTORY_FLAGS(0)).map_err(err)?;
        for index in 0.. {
            let adapter = match factory.EnumAdapters1(index) {
                Ok(adapter) => adapter,
                Err(error) if error.code() == DXGI_ERROR_NOT_FOUND => break,
                Err(error) => return Err(err(error)),
            };
            let desc = adapter.GetDesc1().map_err(err)?;
            let name = String::from_utf16_lossy(&desc.Description);
            let kind = if desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0 {
                "software"
            } else {
                "hardware"
            };
            println!(
                "{index}: {} ({kind}) vendor={:#06x} device={:#06x} luid={:08x}:{:08x}",
                name.trim_end_matches('\0'),
                desc.VendorId,
                desc.DeviceId,
                desc.AdapterLuid.HighPart as u32,
                desc.AdapterLuid.LowPart,
            );
        }
    }
    Ok(())
}

/// Explicit adapter index for physical hardware, otherwise verified WARP.
/// The benchmark is bounded and must be invoked as a standalone CLI.
pub fn run(adapter: Option<u32>, region_bytes: usize, repeats: u32) -> Result<(), String> {
    layout(region_bytes, true)?;
    if !(1..=10).contains(&repeats) {
        return Err("repeats must be 1..10".into());
    }
    // SAFETY: ordinary adapter enumeration and D3D12 device creation.
    let (dev, desc) = unsafe {
        let factory: IDXGIFactory4 = CreateDXGIFactory2(DXGI_CREATE_FACTORY_FLAGS(0)).map_err(err)?;
        let selected: IDXGIAdapter1 = match adapter {
            Some(index) => factory.EnumAdapters1(index).map_err(err)?,
            None => factory.EnumWarpAdapter().map_err(err)?,
        };
        let desc = selected.GetDesc1().map_err(err)?;
        let software = desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0;
        if software != adapter.is_none() {
            return Err("selected adapter does not match requested software/hardware mode".into());
        }
        let mut device: Option<ID3D12Device> = None;
        D3D12CreateDevice(&selected, D3D_FEATURE_LEVEL_12_0, &mut device).map_err(err)?;
        (device.ok_or("no device")?, desc)
    };
    for repeat in 1..=repeats {
        for pooled in [repeat % 2 == 0, repeat % 2 != 0] {
            let s = sample(&dev, region_bytes, pooled)?;
            println!(
                "transfer-v1 adapter={} vendor={:#x} device={:#x} luid={:08x}:{:08x} repeat={} pooled={} region_bytes={} bytes={} allocation_ms={:.6} staging_ms={:.6} upload_fence_ms={:.6} readback_fence_ms={:.6} verified=true",
                if adapter.is_some() { "hardware" } else { "warp" },
                desc.VendorId, desc.DeviceId, desc.AdapterLuid.HighPart as u32, desc.AdapterLuid.LowPart,
                repeat, pooled, region_bytes, s.bytes, s.allocation_ms, s.staging_ms, s.upload_ms, s.readback_ms,
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transfer_layout_and_fence_fail_closed() {
        assert_eq!(layout(512, true).unwrap(), vec![(0, 0), (0, 512), (0, 1024), (0, 1536)]);
        assert_eq!(layout(512, false).unwrap(), vec![(0, 0), (1, 0), (2, 0), (3, 0)]);
        for invalid in [0, 511, 513, MAX_REGION + 512, usize::MAX] {
            assert!(layout(invalid, true).is_err());
        }
        assert!(!fence_done(0, 1).unwrap());
        assert!(fence_done(1, 1).unwrap());
        assert!(fence_done(2, 1).unwrap());
        assert!(fence_done(u64::MAX, 1).is_err());
        assert_ne!(pattern(0), pattern(512));
    }

    #[test]
    fn transfer_warp_smoke() {
        run(None, 4096, 1).expect("verified software adapter transfer");
    }
}
