# ODIN B70 — Intel Arc Pro B70 LLM Inference Server

Automated setup script for running LLM inference on Intel Arc Pro B70 GPUs with vLLM tensor parallelism.

## Performance

| Config | Model | Single Request | 8 Concurrent |
|--------|-------|---------------|--------------|
| 2x B70 (64GB) | Qwen2.5-14B BF16 | 19 tok/s | **140 tok/s** |
| 4x B70 (128GB) | Qwen3.5-27B BF16 | ~14 tok/s | **540 tok/s** |

## Requirements

### Hardware
- 1-4x Intel Arc Pro B70 GPUs ($949 each, 32GB VRAM)
- 16GB+ system RAM (models live entirely in VRAM)
- Motherboard with PCIe x16 slots
- Ubuntu Server 24.04 LTS

### BIOS (must be set manually)
- **Above 4G Decoding**: ENABLED
- **Resizable BAR**: ENABLED
- **CSM**: DISABLED (UEFI only)

Without these settings, the B70 GPUs will not be detected by the OS.

## Quick Start

```bash
# Download
wget https://raw.githubusercontent.com/YOUR_REPO/main/odin-b70-setup.sh
chmod +x odin-b70-setup.sh

# Run (takes 15-30 minutes depending on internet speed)
sudo ./odin-b70-setup.sh

# Reboot (required for new kernel)
sudo reboot

# Start inference server
~/boot_vllm.sh

# Test from any machine on your network
curl http://<SERVER_IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen2.5-14B","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'
```

## What the Script Installs

1. **Kernel 6.17+** — Required for the `xe` driver to recognize Battlemage GPUs
2. **Intel compute-runtime v26.09** — From GitHub, not the APT repo (which is too old for B70)
3. **Intel Graphics Compiler v2.30.1** — Matching IGC version
4. **Docker** — Container runtime for vLLM
5. **`intel/vllm:0.17.0-xpu`** — The correct Docker image for B70 inference (NOT llm-scaler-vllm)
6. **llama.cpp (Vulkan)** — Single-GPU fallback at ~45 tok/s
7. **Qwen2.5-14B-Instruct** — Default model (configurable at top of script)
8. **xpu-smi** — GPU monitoring (power, frequency, VRAM usage)
9. **Systemd service** — Auto-starts Docker container on boot

## Architecture

```
                    ┌─────────────────────────────┐
                    │     Docker Container         │
                    │   intel/vllm:0.17.0-xpu      │
                    │                              │
                    │   vLLM Server (port 8000)    │
                    │   OpenAI-compatible API      │
                    │                              │
                    │   Tensor Parallel (TP=N)     │
                    │   ┌────────┐  ┌────────┐    │
                    │   │ B70 #1 │  │ B70 #2 │    │
                    │   │ 32GB   │  │ 32GB   │    │
                    │   └────────┘  └────────┘    │
                    └─────────────────────────────┘
                              │
                         Port 8000
                              │
                    ┌─────────────────┐
                    │   Your App /    │
                    │   Main PC /     │
                    │   LAN Clients   │
                    └─────────────────┘
```

## Key Technical Details

### Why `intel/vllm:0.17.0-xpu` and NOT `intel/llm-scaler-vllm`?

The `llm-scaler-vllm` image is built for Intel's Best Known Configuration (BKC) stack — Ubuntu 25.04, kernel 6.14, compute-runtime 25.22. Running it on Ubuntu 24.04 with kernel 6.17 and compute-runtime 26.09 causes SYCL worker crashes during tensor parallelism initialization.

`intel/vllm:0.17.0-xpu` was released March 26, 2026 (one day after B70 launched) and is more tolerant of host driver versions. It also dropped the IPEX dependency in favor of `vllm-xpu-kernels v0.1.3`.

### Critical vLLM Flags

| Flag | Why |
|------|-----|
| `--enforce-eager` | **Required.** CUDA graphs crash on Intel XPU. |
| `--disable-custom-all-reduce` | **Required.** Forces oneCCL for inter-GPU communication. |
| `--block-size 64` | Tuned for Arc Pro XMX engines. |
| `--enable-chunked-prefill` | Improves memory utilization and throughput. |
| `--no-enable-prefix-caching` | Prefix caching can cause instability on XPU. |

### Critical Environment Variables

| Variable | Value | Why |
|----------|-------|-----|
| `VLLM_WORKER_MULTIPROC_METHOD` | `spawn` | Required for multi-GPU on XPU. |
| `UR_L0_USE_IMMEDIATE_COMMANDLISTS` | `0` | Prevents Level Zero command list issues. |
| `CCL_TOPO_P2P_ACCESS` | `0` | USM mode — routes allreduce through system RAM. Faster than P2P on PCIe 3.0 without bifurcation. Set to `1` on PCIe 5.0 platforms with x8/x8 bifurcation. |

### GRUB Parameters

| Parameter | Why |
|-----------|-----|
| `iommu=pt` | Passthrough mode. Keeps IOMMU for WiFi/DMA devices but avoids overhead for GPUs. Do NOT use `iommu=off` — breaks WiFi cards with 32-bit DMA (e.g., QCA6174). |
| `pci=realloc` | Allows kernel to reallocate PCIe BARs for large VRAM GPUs. |

### Model Sizing for 2x vs 4x B70

| GPUs | Total VRAM | Max BF16 Model | Recommended |
|------|-----------|----------------|-------------|
| 2x B70 | 64GB | ~14B parameters | Qwen2.5-14B-Instruct |
| 4x B70 | 128GB | ~27B parameters | Qwen3.5-27B |

BF16 uses 2 bytes per parameter. A 14B model = 28GB, split across 2 GPUs = 14GB each, leaving ~18GB per GPU for KV cache and overhead.

27B models OOM on TP=2 due to vLLM's memory overhead. Use TP=4 or INT4 quantization.

## GPU Temperature Monitoring

```bash
# Via lm-sensors (requires kernel 6.17+)
sensors | grep -A3 'xe-pci'

# Via xpu-smi
xpu-smi stats -d 0

# System overview
~/sysinfo.sh
```

## Fallback: llama.cpp Vulkan (Single GPU)

For single-GPU inference with GGUF models, llama.cpp Vulkan delivers ~45-100 tok/s depending on model size:

```bash
# Download a GGUF model
wget https://huggingface.co/unsloth/Nemotron-3-Nano-30B-A3B-GGUF/resolve/main/Nemotron-3-Nano-30B-A3B-Q4_K_M.gguf \
  -O ~/models/nemotron-30b-q4.gguf

# Start
~/start_llamacpp.sh ~/models/nemotron-30b-q4.gguf
```

Note: llama.cpp's Vulkan multi-GPU (layer split) is broken — sequential pipeline with ~4x slowdown. Use vLLM for multi-GPU.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| GPUs not detected in `lspci` | Enable Above 4G Decoding + ReBAR in BIOS, disable CSM |
| `xe` driver not loading | Need kernel 6.17+. Check with `lsmod \| grep xe` |
| `FATAL: Unknown device: deviceId: e223` | Compute-runtime too old. Install v26.09+ from GitHub |
| vLLM TP=2 crashes with OOM | Lower `--gpu-memory-util` to 0.5, reduce `--max-num-seqs` |
| vLLM TP=2 SYCL worker crash | Use `intel/vllm:0.17.0-xpu`, not `llm-scaler-vllm` |
| WiFi broken after adding GPUs | Interface name changed. Check `ip link show` and update netplan |
| WiFi broken with `iommu=off` | Use `iommu=pt` instead — keeps DMA working for 32-bit WiFi cards |
| GPU temps not showing | Only works on kernel 6.17+ via `sensors` command |

## Credits

- [Level1Techs](https://forum.level1techs.com/t/intel-b70-launch-unboxed-and-tested/247873) — 4x B70 benchmark (540 tok/s)
- [vLLM Intel Arc Pro B-Series Blog](https://vllm.ai/blog/intel-arc-pro-b) — Intel's vLLM optimization work
- [intel/vllm](https://hub.docker.com/r/intel/vllm) — Docker images
- [intel/compute-runtime](https://github.com/intel/compute-runtime) — GPU drivers

## License

MIT
