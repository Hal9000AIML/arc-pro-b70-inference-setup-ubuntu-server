#!/usr/bin/env bash
# =============================================================================
# start_coder.sh — Qwen2.5-Coder-14B via llama.cpp Vulkan (Q4_K_M)
# Card: 0 (single GPU)   Port: 8001
#
# Upgraded from 7B BF16 via vLLM to 14B Q4 via llama.cpp Vulkan.
# Q4 on Intel Arc gives 5.5x speedup over Q8, making 14B feasible and fast.
# =============================================================================
set -e

MODEL=/home/brendanhouck/models/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf
PORT=8001

if ! [ -f "$MODEL" ]; then
    echo "ERROR: Model not found at $MODEL"
    echo "Download with: python3 -c \"from huggingface_hub import hf_hub_download; hf_hub_download('bartowski/Qwen2.5-Coder-14B-Instruct-GGUF', 'Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf', local_dir='/home/brendanhouck/models')\""
    exit 1
fi
if curl -sf --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "Coder already healthy on port ${PORT} — skipping start"
    exit 0
fi

export GGML_VK_DEVICE=0
export LLAMA_ARG_DEVICE=Vulkan0

nohup /opt/llama.cpp/llama-b8739/llama-server \
  -m "$MODEL" \
  --host 0.0.0.0 \
  --port ${PORT} \
  --n-gpu-layers 99 \
  --ctx-size 8192 \
  --flash-attn on \
  --parallel 1 \
  --threads 4 \
  --split-mode none \
  --mlock \
  --no-mmap \
  -b 512 \
  > /tmp/llama_coder.log 2>&1 &

echo "Coder 14B Q4 starting on card 0 via llama.cpp Vulkan (PID: $!)..."
