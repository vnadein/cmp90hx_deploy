# CMP 90HX Full Deploy Script

> **English** | [Русский](README_RU.md)

## Overview

This script automates the complete deployment pipeline for the **NVIDIA CMP 90HX** mining GPU, transforming it into a high-performance AI inference accelerator. It combines knowledge from three community research projects to unlock hardware limitations and optimize LLM inference performance.

## What This Script Does

| Stage | Action | Source |
|-------|--------|--------|
| 1 | Installs system dependencies (cmake, git, python3, build tools) | — |
| 2 | Downloads and runs `cmpunlocker v0.1.28` to unlock PCIe Gen3 + Compute | [pearlfortune/cmpunlocker](https://github.com/pearlfortune/cmpunlocker) |
| 3 | Verifies unlock status (`PASS_CMP90HX_ALL_TARGETS_FULL_SPEED`) | [pearlfortune/cmpunlocker](https://github.com/pearlfortune/cmpunlocker) |
| 4 | Clones `llama.cpp`, applies DP2A patch, compiles with CUDA sm_86 | [ggml-org/llama.cpp#24616](https://github.com/ggml-org/llama.cpp/issues/24616) |

## Background: Why This Is Needed

The **CMP 90HX** is a GA102-based GPU (same silicon as RTX 3080) with artificial limitations:

| Parameter | Factory CMP 90HX | After Unlock |
|-----------|-----------------|--------------|
| PCIe Speed | Gen1 x1-4 (~0.85 GB/s) | **Gen3 x16 (~16 GB/s)** |
| DP4A Instruction | Throttled 16x | **Bypassed via DP2A patch** |
| Token Generation | ~30-50 t/s | **~100-120 t/s** |
| FP32 Compute | eFuse locked (1/32 speed) | Cannot be unlocked (hardware) |

### Key Research Findings

From [WildFlash1st/cmp90hx-unlock](https://github.com/WildFlash1st/cmp90hx-unlock) (August 2026):

- **FP32/INT8 SM issue rates are burned into hardware eFuses** — software unlock is impossible
- **VBIOS modification is useless** for compute unlock
- **DP4A instruction is throttled 16x** but **DP2A is NOT throttled**
- **HFMA2 (FP16) CUDA cores are unthrottled** — 59.5 TFLOPS available
- Workaround: Replace DP4A with DP2A emulation in llama.cpp for 2x decode speedup

## Usage

### Clone the repository

```bash
git clone https://github.com/vnadein/cmp90hx_deploy.git
cd cmp90hx_deploy
```

### First-time full deployment

```bash
sudo ./cmp90hx-deploy.sh --all
```

After reboot (unlock is temporary), re-run the unlock step to restore state.

### Check GPU status

```bash
sudo ./cmp90hx-deploy.sh --status
```

### Rebuild llama.cpp (after upstream update)

```bash
sudo ./cmp90hx-deploy.sh --rebuild
```

### Run benchmark

```bash
sudo ./cmp90hx-deploy.sh --benchmark
```

### Install dependencies only

```bash
sudo ./cmp90hx-deploy.sh --deps
```

## Requirements

- **OS:** Linux x86_64 (tested on HiveOS, Ubuntu, Debian)
- **GPU:** NVIDIA CMP 90HX (PCI ID 10de:220d or 10de:1555)
- **Driver:** NVIDIA Open Kernel Modules 580.159.03 or 610.43.03
- **CUDA:** CUDA Toolkit installed
- **Secure Boot:** Disabled
- **Permissions:** Root access required

## Expected Performance After Deployment

Llama-2-7B Q4_0 Benchmark (`llama-bench -p 512 -n 128 -ngl 99`)

| Metric | Stock CMP 90HX | After Script | RTX 3080 (reference) |
|--------|----------------|--------------|----------------------|
| pp512 (prompt processing) | ~160.92 t/s | ~2655.57 t/s | ~3009 t/s |
| tg128 (token generation) | ~37.20 t/s | ~108.25 t/s | ~78 t/s |

Note: Token generation (tg) on CMP 90HX with DP2A patch exceeds RTX 3080 due to higher memory bandwidth utilization in decode phase.

## Model Loading Time

| Model Size | Before Unlock (PCIe Gen1) | After Unlock (PCIe Gen3) |
|------------|---------------------------|--------------------------|
| 7B Q4 (~4GB) | ~45 seconds | ~3 seconds |
| 13B Q4 (~7GB) | ~80 seconds | ~5 seconds |

## Source Repositories

| Repository | Contribution |
|------------|--------------|
| [pearlfortune/cmpunlocker](https://github.com/pearlfortune/cmpunlocker) | PCIe Gen3 unlock, compute unlock tool (v0.1.28) |
| [WildFlash1st/cmp90hx-unlock](https://github.com/WildFlash1st/cmp90hx-unlock) | Hardware research, eFuse analysis, DP4A throttle discovery |
| [ggml-org/llama.cpp#24616](https://github.com/ggml-org/llama.cpp/issues/24616) | DP2A patch implementation (by @arabel1a) |
| [bendy2/cmp90hx](https://github.com/bendy2/cmp90hx) | Alternative unlock method (580.159.03 only, deprecated) |

## Technical Details

### PCIe Unlock Mechanism (pearlfortune/cmpunlocker)

The `cmpunlocker-rs` binary:

- Detects all CMP 90HX cards via PCI ID
- Temporarily unloads NVIDIA driver
- Modifies GPU configuration registers to enable PCIe Gen3
- Reloads driver with unlocked configuration
- State persists until next reboot

### DP2A Patch Mechanism (llama.cpp)

The patch modifies `ggml/src/ggml-cuda/common.cuh`:

- **Before:** Uses `__dp4a()` intrinsic (throttled 16x on CMP 90HX)
- **After:** When compiled with `-DDISABLE_DP4A`, replaces with:
  - 2x `prmt.b32` (byte permute)
  - 2x `dp2a.lo` / `dp2a.hi` (dual packed multiply-accumulate)
- **Result:** 4 instructions instead of 1, but each runs at full speed → net 2x faster

### Why FP32 Cannot Be Unlocked

From eFuse analysis (WildFlash1st, Aug 8 2026):

- SM issue rate modifiers stored in hardware eFuses at registers `0x8207d4-0x8207ec`
- Values: `0x5` = 1/32 speed divider for FP32/INT8 paths
- Write attempts via `GPU_EXEC_REG_OPS` silently ignored by silicon
- GSP-RM firmware is RSA-3K signed, Booter verified in SECURE IMEM
- **Conclusion:** Physical eFuse modification required — impossible via software

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `nvidia-smi` not found | Install NVIDIA Open Driver |
| Checksum MISMATCH | Delete `/var/tmp/cmpunlocker-deploy/` and retry |
| Unlock NOT confirmed | Reboot and run `--unlock` again |
| `common.cuh` not found | llama.cpp structure changed; update patch manually |
| CUDA Toolkit not found | `sudo apt install nvidia-cuda-toolkit` |

## License

This script is provided as-is. Use at your own risk. Modifying GPU parameters may void warranty.

## Disclaimer

- Only use on hardware you own
- The authors are not responsible for hardware damage or data loss
- PCIe and compute unlock may violate NVIDIA's EULA

> **English** | [Русский](README_RU.md)
