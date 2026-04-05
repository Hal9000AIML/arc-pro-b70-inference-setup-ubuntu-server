# ODIN B70 — Intel Arc Pro B70 LLM Inference Server

Automated setup script for running LLM inference on Intel Arc Pro B70 GPUs with vLLM tensor parallelism.

## Hardware

| Component | Spec |
|-----------|------|
| **Motherboard** | ASUS ROG Zenith Extreme X399 |
| **CPU** | AMD Threadripper 1900X (8c/16t) |
| **RAM** | 16GB DDR4-3200 (upgrading to 128GB 4x32GB DDR4-3200) |
| **GPUs** | 4x Intel Arc Pro B70 (128GB VRAM total, 32GB each) |
| **Boot Drive** | 256GB NVMe |
| **Model Storage** | 4TB SSD (arriving) |
| **PSU** | EVGA SuperNOVA 1600 G+ |
| **Case** | Phanteks Enthoo Pro |
| **OS** | Ubuntu Server 24.04 LTS, kernel 6.17+ |

### BIOS Settings (required)
- Above 4G Decoding: **ENABLED**
- Resizable BAR: **ENABLED**
- CSM: **DISABLED** (UEFI only)
- IOMMU: **ENABLED**
- SR-IOV: **ENABLED**
- PCIE_X8/X4_4: **X8 Mode**
- Slow Mode switch on Zenith Extreme: **OFF** (causes PCIe link training failures)

## Performance — Gemma 4 26B-A4B (MoE, 3.8B active params)

### Benchmarked: 4x B70, TP=4, 16GB RAM + 64GB swap

| Concurrency | Aggregate tok/s | Per-request tok/s |
|-------------|----------------|-------------------|
| 1 | 5.7 | 5.7 |
| 4 | 18.6 | ~5.5 |
| 8 | 37.0 | ~5.2 |

**Prompt throughput**: 290-544 tok/s | **GPU temps under load**: 63-71°C pkg, 64-74°C VRAM

> **Note:** These results are swap-bottlenecked. The 16GB system RAM forces vLLM's scheduler and weight loading through NVMe swap at ~3-5 GB/s instead of DDR4 at ~85 GB/s.

### Projected: 4x B70, TP=4, 128GB DDR4-3200 (quad-channel)

| Concurrency | Estimated tok/s | Notes |
|-------------|----------------|-------|
| 1 | 25-35 | MoE with 3.8B active, 4 GPUs |
| 4 | 90-120 | Linear scaling |
| 8 | 160-220 | Approaching GPU compute bound |
| 16 | 280-350 | MoE routing efficient |
| 64 | 420-500 | Near peak throughput |
| 128 | 480-540 | Level1Techs territory, `--max-num-seqs 128` |

### Reference Benchmarks

| Config | Model | Single | 8 Concurrent | Source |
|--------|-------|--------|-------------|--------|
| 2x B70, 16GB RAM | Qwen2.5-14B BF16, TP=2 | 19 tok/s | 140 tok/s | Measured |
| 4x B70, 128GB RAM | Qwen3.5-27B BF16, TP=4 | ~30 tok/s | 540 tok/s | Level1Techs |
| 4x B70, 16GB+swap | Gemma 4 26B-A4B BF16, TP=4 | 5.7 tok/s | 37 tok/s | Measured (swap-limited) |

### Model Sizing for B70 Configurations

| GPUs | Total VRAM | Max BF16 Model | Recommended |
|------|-----------|----------------|-------------|
| 2x B70 | 64GB | ~27B dense | Qwen2.5-14B-Instruct |
| 4x B70 | 128GB | ~60B dense, ~120B MoE | Gemma 4 26B-A4B (50GB BF16, MoE) |

## Quick Start

```bash
# Download
wget https://raw.githubusercontent.com/Hal9000AIML/arc-pro-b70-inference-setup/main/odin-b70-setup.sh
chmod +x odin-b70-setup.sh

# Run (takes 30-60 minutes — builds vLLM from source)
sudo ./odin-b70-setup.sh

# Reboot (required for new kernel)
sudo reboot

# Start inference server
~/boot_vllm.sh

# Test from any machine on your network
curl http://<SERVER_IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-26B-A4B","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'
```

## What the Script Installs

1. **Kernel 6.17+** — Required for the `xe` driver to recognize Battlemage GPUs
2. **Intel compute-runtime v26.09** — From GitHub, not the APT repo (which is too old for B70)
3. **Intel Graphics Compiler v2.30.1** — Matching IGC version
4. **Docker + buildx** — Container runtime and build tools for vLLM
5. **vLLM XPU (built from source)** — Latest main branch with Gemma 4 architecture support
6. **llama.cpp (Vulkan)** — Single-GPU fallback at ~45 tok/s
7. **Gemma 4 26B-A4B** — Default model (MoE, 3.8B active params, 256K context)
8. **Chat template** — Required by transformers 5.x for Gemma 4
9. **xpu-smi** — GPU monitoring (power, frequency, VRAM usage)
10. **Systemd services** — Auto-starts Docker container and thermal watchdog on boot
11. **Swap file** — Auto-created for systems with <64GB RAM

## Architecture

```
                    ┌──────────────────────────────────────────┐
                    │          Docker Container                │
                    │     vllm-xpu:local (built from source)   │
                    │                                          │
                    │     vLLM Server (port 8000)              │
                    │     OpenAI-compatible API                │
                    │                                          │
                    │     Tensor Parallel (TP=4)               │
                    │   ┌────────┐  ┌────────┐               │
                    │   │ B70 #1 │  │ B70 #2 │               │
                    │   │ 32GB   │  │ 32GB   │               │
                    │   ├────────┤  ├────────┤               │
                    │   │ B70 #3 │  │ B70 #4 │               │
                    │   │ 32GB   │  │ 32GB   │               │
                    │   └────────┘  └────────┘               │
                    │         128GB VRAM total                 │
                    └──────────────────────────────────────────┘
                              │
                         Port 8000
                              │
                    ┌─────────────────┐
                    │   Trading Bots  │
                    │   ODIN Agents   │
                    │   LAN Clients   │
                    └─────────────────┘
```

## Key Technical Details

### Why Build vLLM from Source?

The pre-built `intel/vllm:0.17.0-xpu` image (March 26, 2026) predates Gemma 4's release (April 2, 2026). The `gemma4` architecture support was merged via PR #38826 on April 2. Building from the latest vLLM main branch includes this plus Intel's FusedMoE XPU kernels optimized for Arc Pro B-series.

The transformers library must also be upgraded to 5.x inside the container, as the Gemma 4 architecture is too new for the 4.x series that vLLM pins.

### Why `--privileged` Container?

The newer oneCCL (2021.15.7) requires access to Level Zero IPC device file descriptors for inter-GPU communication. Without `--privileged`, the `ze_fd_manager` fails with "could not open device directory" errors during TP initialization. The older `intel/vllm:0.17.0-xpu` image used a different oneCCL version that worked without `--privileged`.

### Critical vLLM Flags

| Flag | Why |
|------|-----|
| `--enforce-eager` | **Required.** CUDA graphs crash on Intel XPU. |
| `--disable-custom-all-reduce` | **Required.** Forces oneCCL for inter-GPU communication. |
| `--block-size 64` | Tuned for Arc Pro XMX engines. |
| `--enable-chunked-prefill` | Improves memory utilization and throughput. |
| `--no-enable-prefix-caching` | Prefix caching can cause instability on XPU. |
| `--chat-template` | **Required for Gemma 4.** Tokenizer lacks built-in chat template. |
| `--gpu-memory-util 0.85` | Leaves headroom for KV cache growth under concurrency. |

### Critical Environment Variables

| Variable | Value | Why |
|----------|-------|-----|
| `VLLM_WORKER_MULTIPROC_METHOD` | `spawn` | Required for multi-GPU on XPU. |
| `UR_L0_USE_IMMEDIATE_COMMANDLISTS` | `0` | Prevents Level Zero command list issues. |
| `CCL_TOPO_P2P_ACCESS` | `0` | USM mode — routes allreduce through system RAM. Faster than P2P on PCIe 3.0 without bifurcation. Set to `1` on PCIe 5.0 platforms with x8/x8 bifurcation. |

### RAM and Performance

| RAM | Swap Needed | `--max-num-seqs` | Expected Generation tok/s (8 concurrent) |
|-----|------------|-------------------|------------------------------------------|
| 16GB | 64GB | 8 | ~37 (swap-bottlenecked) |
| 32GB | 32GB | 16-32 | ~80-120 |
| 64GB | None | 64 | ~200-350 |
| 128GB | None | 128 | ~400-540 |

The CPU-side scheduler, tokenization, and oneCCL USM inter-GPU traffic all flow through host RAM. With 16GB, these operations page through NVMe swap at 3-5 GB/s. DDR4-3200 quad-channel delivers ~85 GB/s — a 20x improvement.

### GPU Thermal Monitoring

The script installs a systemd thermal watchdog (`gpu-thermal-watchdog.service`) that monitors all B70 GPUs every 30 seconds. If any GPU package or VRAM temperature reaches 90°C, it automatically stops vLLM for thermal protection.

Observed temperatures under sustained load:
- Idle: 52-58°C package, 56-62°C VRAM
- Under load (8 concurrent): 63-71°C package, 64-74°C VRAM
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

## Fallback: llama.cpp Vulkan (Single GPU)

For single-GPU inference with GGUF models, llama.cpp Vulkan delivers ~45-100 tok/s depending on model size:

```bash
# Download a GGUF model
wget https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-Q4_K_M.gguf \
  -O ~/models/gemma4-26b-q4.gguf

# Start
~/start_llamacpp.sh ~/models/gemma4-26b-q4.gguf
```

Note: llama.cpp's Vulkan multi-GPU (layer split) is broken — sequential pipeline with ~4x slowdown (bug #16767). Use vLLM for multi-GPU.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| GPUs not detected in `lspci` | Enable Above 4G Decoding + ReBAR in BIOS, disable CSM |
| `xe` driver not loading | Need kernel 6.17+. Check with `lsmod \| grep xe` |
| `FATAL: Unknown device: deviceId: e223` | Compute-runtime too old. Install v26.09+ from GitHub |
| vLLM `gemma4` architecture not recognized | Upgrade transformers: `pip install 'transformers>=4.59'` |
| vLLM `Cannot allocate memory` during model load | Need more RAM or swap. Script auto-creates swap for <64GB systems |
| vLLM oneCCL `opendir failed` / `device_fd invalid` | Use `--privileged` container flag |
| vLLM TP=2 crashes with OOM | Lower `--gpu-memory-util` to 0.5, reduce `--max-num-seqs` |
| Thermal watchdog false trigger | Ensure watchdog filters MJ/W sensor lines (fixed in v1.2.1) |
| WiFi broken after adding GPUs | Interface name changed. Check `ip link show` and update netplan |
| WiFi broken with `iommu=off` | Use `iommu=pt` instead — keeps DMA working for 32-bit WiFi cards |
| Slow Mode switch causes POST code 99 | Turn OFF the Slow Mode switch on Zenith Extreme |
| BIOS bricked after EFI variable write | Use BIOS Flashback to recover — CMOS clear does NOT reset EFI NVRAM |

## Credits

- [Level1Techs](https://forum.level1techs.com/t/intel-b70-launch-unboxed-and-tested/247873) — 4x B70 benchmark (540 tok/s)
- [vLLM Intel Arc Pro B-Series Blog](https://vllm.ai/blog/intel-arc-pro-b) — Intel's vLLM optimization work
- [Run Gemma 4 on Intel Arc GPUs](https://huggingface.co/blog/MatrixYao/intel-gpu) — Intel's Day 0 Gemma 4 XPU guide
- [intel/vllm](https://hub.docker.com/r/intel/vllm) — Docker images
- [intel/compute-runtime](https://github.com/intel/compute-runtime) — GPU drivers

## License

MIT
