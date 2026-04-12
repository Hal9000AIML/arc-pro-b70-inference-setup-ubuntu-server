#!/usr/bin/env bash
# Gemma 4 26B-A4B — llama.cpp SYCL1 (BDF 10:00.0, x16, Die 0), Q8_0, port 8000
source /opt/intel/oneapi/setvars.sh --force 2>/dev/null
export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1
export GGML_SYCL_ENABLE_FLASH_ATTN=1
export SYCL_CACHE_PERSISTENT=0
export ZES_ENABLE_SYSMAN=1
exec /opt/llama.cpp/llama-sycl-build/bin/llama-server \
    --model /mnt/models/gemma-4-26B-A4B-it-Q8_0.gguf \
    --device SYCL1 \
    -ngl 999 \
    -c 32768 \
    --parallel 2 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --defrag-thold 0.1 \
    --host 0.0.0.0 --port 8000 \
    --alias gemma-4-26B-A4B \
    -t 1 \
    --chat-template-file /mnt/models/gemma-4-26B-A4B-it/chat_template.jinja \
    --jinja \
    --reasoning off \
    --no-warmup \
    --log-file /tmp/llama-gemma.log
