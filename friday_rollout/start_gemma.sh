#!/usr/bin/env bash
# =============================================================================
# start_gemma.sh — Gemma 4 26B-A4B via llama.cpp Vulkan (Q4_K_M)
# Card: 3 (single GPU)   Port: 8000
#
# Key findings (2026-04-10):
# - Q4 quantization is 5.5x faster than Q8 on Intel Arc B70
# - llama.cpp Vulkan outperforms vLLM for single-card inference
# - TP=2 crashes with BCS engine resets (xe driver bug with current compute-runtime)
# - FP8 vLLM gave ~6.5 tok/s; Q4 Vulkan gives ~18.7 tok/s
# =============================================================================
set -e

MODEL=/home/brendanhouck/models/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf
PORT=8000

if ! [ -f "$MODEL" ]; then
    echo "ERROR: Model not found at $MODEL"
    echo "Download with: python3 -c \"from huggingface_hub import hf_hub_download; hf_hub_download('unsloth/gemma-4-26B-A4B-it-GGUF', 'gemma-4-26B-A4B-it-UD-Q4_K_M.gguf', local_dir='/home/brendanhouck/models')\""
    exit 1
fi
if curl -sf --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "Gemma already healthy on port ${PORT} — skipping start"
    exit 0
fi

export GGML_VK_DEVICE=3
export LLAMA_ARG_DEVICE=Vulkan3

nohup /opt/llama.cpp/llama-b8739/llama-server \
  -m "$MODEL" \
  --host 0.0.0.0 \
  --port ${PORT} \
  --n-gpu-layers 99 \
  --ctx-size 8192 \
  --flash-attn on \
  --parallel 1 \
  --threads 2 \
  --split-mode none \
  --mlock \
  --no-mmap \
  -b 512 \
  > /tmp/llama_gemma.log 2>&1 &

echo "Gemma 4 26B Q4 starting on card 3 via llama.cpp Vulkan (PID: $!)..."
