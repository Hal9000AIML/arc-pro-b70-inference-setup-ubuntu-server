#!/usr/bin/env bash
# Qwen3.5-9B — llama.cpp SYCL2 (BDF 43:00.0, x8, Die 1), Q4_K_M, port 8002
source /opt/intel/oneapi/setvars.sh --force 2>/dev/null
export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1
export GGML_SYCL_ENABLE_FLASH_ATTN=1
export SYCL_CACHE_PERSISTENT=0
export ZES_ENABLE_SYSMAN=1
exec /opt/llama.cpp/llama-sycl-build/bin/llama-server \
    --model /mnt/models/Qwen_Qwen3.5-9B-Q4_K_M.gguf \
    --device SYCL2 \
    -ngl 999 \
    -c 32768 \
    --parallel 2 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --defrag-thold 0.1 \
    --host 0.0.0.0 --port 8002 \
    --alias Qwen3.5-9B \
    -t 1 \
    --reasoning off \
    --no-warmup \
    --log-file /tmp/llama-fast.log
