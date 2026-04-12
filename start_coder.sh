#!/usr/bin/env bash
# Qwen2.5-Coder-14B — llama.cpp SYCL3 (BDF 44:00.0, x16, Die 1), Q4_K_M, port 8001
source /opt/intel/oneapi/setvars.sh --force 2>/dev/null
export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1
export GGML_SYCL_ENABLE_FLASH_ATTN=1
export SYCL_CACHE_PERSISTENT=0
export ZES_ENABLE_SYSMAN=1
exec /opt/llama.cpp/llama-sycl-build/bin/llama-server \
    --model /mnt/models/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf \
    --device SYCL3 \
    -ngl 999 \
    -c 32768 \
    --parallel 2 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --defrag-thold 0.1 \
    --host 0.0.0.0 --port 8001 \
    --alias Qwen2.5-Coder-14B \
    -t 1 \
    --no-warmup \
    --log-file /tmp/llama-coder.log
