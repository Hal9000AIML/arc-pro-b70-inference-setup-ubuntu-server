# Intel Arc Pro B70 LLM Inference Server — Ubuntu Server Edition

> **Ubuntu Server 24.04 LTS** install. For the Windows installer, see
> [arc-pro-b70-inference-setup-windows](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-windows).
>
> **After setup, apply the performance tuning kit** at
> [arc-pro-b70-ubuntu-llm-inference-kit](https://github.com/Hal9000AIML/arc-pro-b70-ubuntu-llm-inference-kit)
> to get the 11 cherry-picks (MoE MMVQ, Xe2 warptile, Q8_0 reorder fix, etc.),
> Mesa 26 PPA, backend-selection rules, and env vars (`GGML_SYCL_DISABLE_OPT=1`)
> that actually make the cards fast. Without those, llama.cpp on B70 leaves 2–7×
> on the floor and MoE models SEGV at slot init.

Automated setup script for running LLM inference on Intel Arc Pro B70 GPUs with llama.cpp SYCL — four independent model slots, one per card, each on its own port.

## The three-repo picture

| Repo | What it does | When you want it |
|---|---|---|
| **this repo** | Bare-metal Ubuntu installer: autoinstall ISO, BIOS guide, DDR4 tuning, GuC firmware 70.60.0, systemd + watchdog, first-boot service | Building a box from scratch. Start here. |
| [arc-pro-b70-ubuntu-llm-inference-kit](https://github.com/Hal9000AIML/arc-pro-b70-ubuntu-llm-inference-kit) | llama.cpp tuning kit: 11 cherry-picks, Mesa PPA, per-model start scripts, SYCL-vs-Vulkan rules, benchmark guardrails | After the box is up, to get production-grade tok/s and MoE stability |
| [arc-pro-b70-inference-setup-windows](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-windows) | Windows (WSL2 + Docker) installer for vLLM XPU TP=4 | You're on Windows and want single-model vLLM tensor parallelism |

## Hardware

| Component | Spec |
|-----------|------|
| **Motherboard** | ASUS ROG Zenith Extreme X399 |
| **CPU** | AMD Threadripper 1900X (8c/16t) |
| **RAM** | 128GB DDR4-3200 (4x32GB, quad-channel, installed 2026-04-10) |
| **GPUs** | 4x Intel Arc Pro B70 (128GB VRAM total, 32GB each) |
| **Boot Drive** | 256GB NVMe |
| **Model Storage** | 4TB SSD |
| **PSU** | EVGA SuperNOVA 1600 G+ |
| **Case** | Phanteks Enthoo Pro |
| **OS** | Ubuntu Server 24.04 LTS, kernel 6.17+ |

> **RAM speed note:** The Threadripper 1900X memory controller officially supports DDR4-2400, with the X399
> platform (Zenith Extreme) pushing up to DDR4-2666 reliably at full population (4 DIMMs, one per channel).
> DDR4-3200 XMP/DOCP profiles typically fail to train at 4×32GB on 1st-gen Threadripper. Run at stock
> (2666 MHz) or DOCP 2933 MHz — do not force 3200, it will cause random reboots under memory pressure.
> Quad-channel DDR4-2666 still delivers ~70–75 GB/s real-world bandwidth, which is the target for
> eliminating swap bottlenecks.

### BIOS Settings (required)
- Above 4G Decoding: **ENABLED**
- Resizable BAR: **ENABLED**
- CSM: **DISABLED** (UEFI only)
- IOMMU: **ENABLED**
- SR-IOV: **ENABLED**
- PCIE_X8/X4_4: **X8 Mode**
- Slow Mode switch on Zenith Extreme: **OFF** (causes PCIe link training failures)
- Memory: **DOCP 2666** (or stock 2400) — do not enable 3200 XMP at full 4-DIMM population

## Model Layout

Four independent llama.cpp SYCL servers, one per B70 card, each pinned to its PCIe slot:

| Port | Model | Quant | Device | PCIe Slot | Die |
|------|-------|-------|--------|-----------|-----|
| 8000 | Gemma 4 26B-A4B | Q8_0 | SYCL1 (BDF 10:00.0) | x16 | Die 0 |
| 8001 | Qwen3-14B | Q8_0 | SYCL3 (BDF 44:00.0) | x16 | Die 1 |
| 8002 | Qwen3.5-9B | Q4_K_M | SYCL2 (BDF 43:00.0) | x8 | Die 1 |
| 8003 | RedSage-Qwen3-8B | Q4_K_M | Vulkan (card 1) | x8 | Die 0 |

Each server is fully independent — different models, contexts, and ports. No tensor parallelism, no shared state.

## Performance

Benchmarks with 128GB RAM installed (no swap):

| Model | Port | Context | Parallel Slots | Est. tok/s |
|-------|------|---------|---------------|-----------|
| Gemma 4 26B-A4B Q8_0 | 8000 | 32768 | 2 | ~25-35 single |
| Qwen3-14B Q8_0 | 8001 | 32768 | 2 | ~40-55 single |
| Qwen3.5-9B Q4_K_M | 8002 | 32768 | 2 | ~60-80 single |
| RedSage-Qwen3-8B Q4_K_M | 8003 | 8192 | 1 | ~50-70 single |

> **Note:** These are estimates pending full benchmarks with 128GB RAM. Prior vLLM numbers (5.7 tok/s
> single, 37 tok/s @ 8 concurrent) were swap-bottlenecked on 16GB RAM — not representative of current
> hardware.

### Reference Benchmarks

| Config | Model | Single | 8 Concurrent | Source |
|--------|-------|--------|-------------|--------|
| 2x B70, 16GB RAM | Qwen2.5-14B BF16, TP=2 | 19 tok/s | 140 tok/s | Measured (vLLM, swap) |
| 4x B70, 128GB RAM | Qwen3.5-27B BF16, TP=4 | ~30 tok/s | 540 tok/s | Level1Techs |

## Quick Start

There are two ways to bring up a fresh machine:

### Option A — Bootable USB (recommended for clean hardware)

Builds an Ubuntu 24.04 Server autoinstall USB that lays down the OS and runs
the full stack setup automatically on first boot. No manual steps after disk
selection.

```bash
# On any Linux box or WSL — install build deps once
sudo apt-get install -y xorriso p7zip-full wget

# Clone and build the ISO (downloads Ubuntu 24.04.2 ~3 GB on first run)
git clone https://github.com/Hal9000AIML/arc-pro-b70-inference-setup.git
cd arc-pro-b70-inference-setup
bash build_iso.sh

# Output: arc-pro-b70-autoinstall.iso (~3 GB)
# Write to USB with Rufus (DD mode), Balena Etcher, or:
sudo dd if=arc-pro-b70-autoinstall.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**On the target machine:**
1. Boot from USB and select **"Install Intel Arc Pro B70 Inference Server (autoinstall)"** (default, 10s timeout)
2. Installer runs unattended but **pauses on storage** so you confirm the target disk (protection against wiping the wrong machine)
3. Reboots into Ubuntu 24.04 — login as `user` / `changeme`
4. `prob70-firstboot.service` automatically runs `odin-b70-setup.sh`
5. Watch progress: `sudo journalctl -fu prob70-firstboot`

The first-boot service is idempotent — it touches `/var/lib/prob70/installed` on success and won't re-run on subsequent boots. Total time from USB boot to working inference endpoints: ~30-60 minutes (llama.cpp SYCL build is faster than the old vLLM source build).

### Option B — Manual install on existing Ubuntu

```bash
# Download
wget https://raw.githubusercontent.com/Hal9000AIML/arc-pro-b70-inference-setup/main/odin-b70-setup.sh
chmod +x odin-b70-setup.sh

# Run (takes 20-40 minutes — builds llama.cpp with SYCL backend)
sudo ./odin-b70-setup.sh

# Reboot (required for new kernel)
sudo reboot

# Start all four inference servers
~/start_gemma.sh &
~/start_coder.sh &
~/start_fast.sh &
~/start_redsage.sh &

# Test
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-26B-A4B","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'
```

## What the Script Installs

1. **Kernel 6.17+** — Required for the `xe` driver to recognize Battlemage GPUs
2. **Intel compute-runtime v26.09** — From GitHub, not the APT repo (which is too old for B70)
3. **Intel Graphics Compiler v2.30.1** — Matching IGC version
4. **Intel oneAPI Base Toolkit** — SYCL runtime, Level Zero, oneMKL
5. **llama.cpp (SYCL backend, built from source)** — OpenCL-free SYCL path; each card runs as an independent server
6. **llama.cpp (Vulkan backend)** — For RedSage on the x8 slot (port 8003); also useful for GGUF fallback
7. **Gemma 4 26B-A4B Q8_0** — Default primary model; 32K context, 2 parallel slots
8. **Qwen3-14B Q8_0** — Coding/reasoning model; `--reasoning off` for direct mode
9. **Qwen3.5-9B Q4_K_M** — Fast general model; fits in 32GB with room to spare
10. **RedSage-Qwen3-8B Q4_K_M** — Cybersecurity-specialized model (port 8003, Vulkan)
11. **xpu-smi** — GPU monitoring (power, frequency, VRAM usage)
12. **Systemd services** — Auto-starts all four servers on boot
13. **Chat templates** — `.jinja` templates for models that require them (Gemma 4)

## Architecture

```
  ┌──────────────────────────────────────────────────────────┐
  │                   Ubuntu 24.04 Host                      │
  │                                                          │
  │  Port 8000           Port 8001           Port 8002       │
  │  llama-server        llama-server        llama-server    │
  │  Gemma 4 26B         Qwen3-14B           Qwen3.5-9B      │
  │  Q8_0                Q8_0                Q4_K_M          │
  │  ┌──────────┐        ┌──────────┐        ┌──────────┐    │
  │  │  B70 #1  │        │  B70 #3  │        │  B70 #2  │    │
  │  │  SYCL1   │        │  SYCL3   │        │  SYCL2   │    │
  │  │  32GB    │        │  32GB    │        │  32GB    │    │
  │  │  x16     │        │  x16     │        │  x8      │    │
  │  └──────────┘        └──────────┘        └──────────┘    │
  │                                                          │
  │  Port 8003                                               │
  │  llama-server                                            │
  │  RedSage-8B Q4_K_M                                       │
  │  ┌──────────┐                                            │
  │  │  B70 #4  │                                            │
  │  │  Vulkan  │                                            │
  │  │  32GB    │                                            │
  │  │  x8      │                                            │
  │  └──────────┘                                            │
  └──────────────────────────────────────────────────────────┘
                          │
              Ports 8000–8003 (OpenAI-compatible)
                          │
         ┌────────────────────────────────┐
         │  ODIN Agents / Trading Bots    │
         │  LAN Clients (192.168.1.x)     │
         └────────────────────────────────┘
```

Each server exposes an OpenAI-compatible `/v1/chat/completions` endpoint. ODIN routes by model tier: primary (8000), coder (8001), fast (8002), security (8003).

## Key Technical Details

### Why llama.cpp SYCL Instead of vLLM?

vLLM XPU requires `--enforce-eager` (no CUDA graphs on Intel XPU) and a `--privileged` Docker container for oneCCL inter-GPU communication. At 4x TP=4, vLLM was bottlenecked by the host-side scheduler and oneCCL USM traffic through system RAM — the reason the 16GB swap benchmark produced only 5.7 tok/s single.

llama.cpp SYCL sidesteps all of this:
- No Docker, no container overhead, runs directly on the host
- No inter-GPU communication — each card is fully independent
- No Python scheduler — C++ server with minimal overhead
- Each `llama-server` process pins to one `--device SYCL{n}` via Level Zero

The tradeoff is no tensor parallelism (can't spread one 60B+ model across cards). For the current model sizes (8B–26B), single-card fits fine in 32GB.

### Critical llama.cpp SYCL Flags

| Flag | Value | Why |
|------|-------|-----|
| `--device` | `SYCL0`–`SYCL3` | Pins server to one specific B70 card |
| `-ngl 999` | — | Offload all layers to GPU (no CPU fallback) |
| `-c` | `32768` | 32K context per slot |
| `--parallel` | `2` | Two simultaneous requests per server |
| `--batch-size` | `2048` | KV cache fill batch — tuned for B70 XMX engines |
| `--ubatch-size` | `512` | Micro-batch for prompt processing |
| `--defrag-thold` | `0.1` | KV cache defrag at 10% fragmentation |
| `-t` | `1` | One CPU decode thread (GPU-bound; more threads waste) |
| `--no-warmup` | — | Skip warmup inference on start (faster boot) |
| `--reasoning off` | — | Qwen3 models: suppress `<think>` blocks for direct output |
| `--jinja` | — | Required for models with `.jinja` chat templates |

### Critical Environment Variables

| Variable | Value | Why |
|----------|-------|-----|
| `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS` | `1` | Allows SYCL USM allocations up to device VRAM limit |
| `GGML_SYCL_ENABLE_FLASH_ATTN` | `1` | Enable FlashAttention on B70 XMX engines (~20% throughput gain) |
| `SYCL_CACHE_PERSISTENT` | `0` | Disable persistent JIT cache (avoids stale kernels after driver updates) |
| `ZES_ENABLE_SYSMAN` | `1` | Required for xpu-smi / sysman power and temp monitoring |

### RAM and Performance

With 128GB installed, all scheduler, tokenization, and embedding traffic runs in DDR4 instead of NVMe swap. The prior 16GB baseline:

| RAM | Swap Needed | `--parallel` | Observed tok/s (Gemma single) |
|-----|------------|--------------|-------------------------------|
| 16GB | 64GB NVMe | 1 | 5.7 (swap-bottlenecked, vLLM TP=4) |
| 128GB | None | 2 per server | ~25-35 (estimated, llama.cpp SYCL) |

> **RAM speed caveat:** See hardware note above — with 4x32GB on Threadripper 1900X, run DOCP 2666
> (not 3200). Quad-channel DDR4-2666 gives ~70–75 GB/s real-world, vs. ~3–5 GB/s through NVMe swap.

### GPU Thermal Monitoring

The script installs a systemd thermal watchdog (`gpu-thermal-watchdog.service`) that monitors all B70 GPUs every 30 seconds. If any GPU package or VRAM temperature reaches 90°C, it automatically stops inference servers for thermal protection.

Observed temperatures under sustained load:
- Idle: 52-58°C package, 56-62°C VRAM
- Under load (2 parallel slots): 63-71°C package, 64-74°C VRAM
- Throttle point: ~95°C
- Thermal shutdown: ~110°C

```bash
# Check temperatures
sensors | grep -A3 'xe-pci'

# Check watchdog status
sudo systemctl status gpu-thermal-watchdog

# Check thermal log
cat /var/log/gpu_thermal.log
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| GPUs not detected in `lspci` | Enable Above 4G Decoding + ReBAR in BIOS, disable CSM |
| `xe` driver not loading | Need kernel 6.17+. Check with `lsmod \| grep xe` |
| `FATAL: Unknown device: deviceId: e223` | Compute-runtime too old. Install v26.09+ from GitHub |
| llama.cpp SYCL `SYCL device not found` | Source oneAPI setvars: `source /opt/intel/oneapi/setvars.sh` |
| llama.cpp can't allocate VRAM | Check `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1` is set |
| Two servers try to use the same card | Verify `--device SYCL{n}` is unique per start script |
| Memory won't train at DDR4-3200 | Expected on TR 1900X at 4 DIMMs — use DOCP 2666 or stock 2400 |
| Thermal watchdog false trigger | Ensure watchdog filters MJ/W sensor lines (fixed in v1.2.1) |
| WiFi broken after adding GPUs | Interface name changed. Check `ip link show` and update netplan |
| WiFi broken with `iommu=off` | Use `iommu=pt` instead — keeps DMA working for 32-bit WiFi cards |
| Slow Mode switch causes POST code 99 | Turn OFF the Slow Mode switch on Zenith Extreme |
| BIOS bricked after EFI variable write | Use BIOS Flashback to recover — CMOS clear does NOT reset EFI NVRAM |
| Gemma chat output garbled | Pass `--chat-template-file` + `--jinja`; Gemma 4 requires its `.jinja` template |

## Credits

- [Level1Techs](https://forum.level1techs.com/t/intel-b70-launch-unboxed-and-tested/247873) — 4x B70 benchmark (540 tok/s, vLLM TP=4)
- [vLLM Intel Arc Pro B-Series Blog](https://vllm.ai/blog/intel-arc-pro-b) — Intel's vLLM optimization work
- [Run Gemma 4 on Intel Arc GPUs](https://huggingface.co/blog/MatrixYao/intel-gpu) — Intel's Day 0 Gemma 4 XPU guide
- [intel/compute-runtime](https://github.com/intel/compute-runtime) — GPU drivers
- [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) — SYCL backend

## License

MIT
