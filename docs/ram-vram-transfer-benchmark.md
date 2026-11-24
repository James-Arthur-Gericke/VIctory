# Synthetic RAM-to-default-heap transfer benchmark (V3.1 workflow 4)

Standalone Windows CLI, no title assets or execution. Start with verified WARP:

    victory-diag.exe transfer-benchmark --region-bytes 4096 --repeats 1

List the DXGI adapters before choosing an index. This only queries adapter descriptions and does not create a D3D12 device or submit transfers:

    victory-diag.exe transfer-benchmark --list-adapters

On a supervised physical test machine, pass the index of the intended hardware adapter and confirm its vendor, device, and LUID in the benchmark output. Adapter indices depend on the machine:

    victory-diag.exe transfer-benchmark --adapter 0 --region-bytes 262144 --repeats 3

Repeat for 4096, 262144, 1048576 and 16777216 bytes per region. Four regions, max 64 MiB payload per sample; at most ten repeated pairs. Alternates dedicated upload resources versus one pooled upload resource with disjoint 512-byte-aligned offsets. The benchmark is a synthetic analogue of V3 staging, not a measurement of its live texture upload allocator. Separately reports allocation (upload/default/readback), CPU staging (map/copy/unmap), upload submission-to-fence wall time and readback submission-to-fence wall time. Bytes divided by upload time gives effective fence-confirmed throughput, not raw PCIe bandwidth or GPU-only timestamp duration. Polling/scheduler overhead dominates tiny transfers. Source generation and full byte verification are outside measured transfer intervals.

DEFAULT buffers use D3D12 COMMON promotion/decay across separately fence-confirmed submissions; fixed upload and readback heap states. See Microsoft resource barrier documentation. Every byte is verified after readback; no success sample on mismatch, device removal, fence sentinel, signal failure or timeout. On unconfirmed completion the standalone CLI exits without resetting or reusing in-flight objects. A timeout cannot interrupt a blocked driver call; supervise hardware tests and stop on driver failure. No watchdog changes. WARP is correctness only; UMA/default heap is not necessarily discrete VRAM. GPU residency budgets are separate from throughput. No physical measurements claimed. Raw results outside repository.
