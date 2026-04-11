#!/usr/bin/env bash
# Gemma 4 26B-A4B — llama.cpp Vulkan3 (BDF 47:00.0, x16, Die 1), Q4_K_M, port 8000
# --parallel 2: 32768/2 = 16384 tokens per slot (fits ODIN conversations)
exec /opt/llama.cpp/llama-b8739/llama-server \
    --model /mnt/models/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf \
    --device Vulkan3 \
    -ngl 999 \
    -c 32768 \
    --parallel 2 \
    --batch-size 512 \
    --host 0.0.0.0 --port 8000 \
    --alias gemma-4-26B-A4B \
    -t 2 \
    --chat-template-file /mnt/models/gemma-4-26B-A4B-it/chat_template.jinja \
    --jinja \
    --reasoning off \
    --log-file /tmp/llama-gemma.log
