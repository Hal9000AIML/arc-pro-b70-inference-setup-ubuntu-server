#!/usr/bin/env bash
# Qwen3-8B — llama.cpp Vulkan2 (BDF 43:00.0, x8, Die 1), Q4_K_M, port 8002
exec /opt/llama.cpp/llama-b8739/llama-server \
    --model /mnt/models/Qwen3-8B-Q4_K_M.gguf \
    --device Vulkan2 \
    -ngl 999 \
    -c 16384 \
    --parallel 32 \
    --batch-size 512 \
    --host 0.0.0.0 --port 8002 \
    --alias Qwen3-8B \
    -t 2 \
    --reasoning off \
    --log-file /tmp/llama-fast.log
