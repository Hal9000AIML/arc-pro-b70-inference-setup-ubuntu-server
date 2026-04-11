#!/usr/bin/env bash
# Qwen2.5-Coder-14B — llama.cpp Vulkan0 (BDF 0c:00.0, x8, Die 0), Q4_K_M, port 8001
exec /opt/llama.cpp/llama-b8739/llama-server \
    --model /mnt/models/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf \
    --device Vulkan0 \
    -ngl 999 \
    -c 32768 \
    --parallel 16 \
    --batch-size 512 \
    --host 0.0.0.0 --port 8001 \
    --alias Qwen2.5-Coder-14B \
    -t 2 \
    --log-file /tmp/llama-coder.log
