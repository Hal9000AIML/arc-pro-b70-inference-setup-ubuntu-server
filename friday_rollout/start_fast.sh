#!/usr/bin/env bash
# =============================================================================
# start_fast.sh — Qwen3-8B via llama.cpp Vulkan (Q4_K_M)
# Card: 2 (single GPU)   Port: 8002
#
# Switched from vLLM FP8 (28.8 tok/s) to llama.cpp Vulkan Q4 (44.5 tok/s)
# =============================================================================
set -e

MODEL=/home/brendanhouck/models/Qwen3-8B-Q4_K_M.gguf
PORT=8002

if ! [ -f "$MODEL" ]; then
    echo "ERROR: Model not found at $MODEL"
    echo "Download with: python3 -c \"from huggingface_hub import hf_hub_download; hf_hub_download('unsloth/Qwen3-8B-GGUF', 'Qwen3-8B-Q4_K_M.gguf', local_dir='/home/brendanhouck/models')\""
    exit 1
fi
if curl -sf --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "Fast model already healthy on port ${PORT} — skipping start"
    exit 0
fi

export GGML_VK_DEVICE=2
export LLAMA_ARG_DEVICE=Vulkan2

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
  > /tmp/llama_fast.log 2>&1 &

echo "Qwen3-8B Q4 starting on card 2 via llama.cpp Vulkan (PID: $!)..."
