#!/usr/bin/env bash
# =============================================================================
# start_redsage.sh — RedSage-Qwen3-8B pentesting LLM via llama.cpp Vulkan (Q4_K_M)
# Card: 1 (single GPU)   Port: 8003
#
# Purpose-built cybersecurity model (266K security dialogues, ICLR'26)
# Generates nmap/sqlmap/metasploit commands, offensive + defensive security
# ODIN Kali agent routes to this via tier="security"
# =============================================================================
set -e

MODEL=/home/brendanhouck/models/RedSage-Qwen3-8B-DPO.i1-Q4_K_M.gguf
PORT=8003

if ! [ -f "$MODEL" ]; then
    echo "ERROR: Model not found at $MODEL"
    echo "Download with: python3 -c \"from huggingface_hub import hf_hub_download; hf_hub_download('mradermacher/RedSage-Qwen3-8B-DPO-i1-GGUF', 'RedSage-Qwen3-8B-DPO.i1-Q4_K_M.gguf', local_dir='/home/brendanhouck/models')\""
    exit 1
fi
if curl -sf --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "RedSage already healthy on port ${PORT} — skipping start"
    exit 0
fi

export GGML_VK_DEVICE=1
export LLAMA_ARG_DEVICE=Vulkan1

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
  > /tmp/llama_redsage.log 2>&1 &

echo "RedSage Q4 starting on card 1 via llama.cpp Vulkan (PID: $!)..."
