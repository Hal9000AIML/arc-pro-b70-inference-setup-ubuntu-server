#!/usr/bin/env bash
# =============================================================================
# start_coder.sh — Tier 2 code LLM: Qwen2.5-Coder-14B-Instruct (FP8)
# Card: 0 (TP=1)    Port: 8001    Container: vllm-b70-coder
#
# Dense 14B model, ~14GB at FP8, fits on one B70 with room for KV cache.
# Note: Qwen3-Coder-30B-A3B was tested but its 30GB FP8 weights leave no
# room for KV cache on a 32GB card. GPTQ 4-bit also failed — vLLM XPU
# doesn't have gptq_shuffle kernels compiled.
# =============================================================================
set -e
CONT=vllm-b70-coder
MODEL=/llm/models/Qwen2.5-Coder-14B-Instruct
PORT=8001

if ! docker ps --format '{{.Names}}' | grep -q "^${CONT}$"; then
    echo "ERROR: Container ${CONT} is not running."
    exit 1
fi
if curl -sf --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "Coder already healthy on port ${PORT} — skipping start"
    exit 0
fi

docker exec -d "${CONT}" bash -c "
export ZE_AFFINITY_MASK=0
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export UR_L0_USE_IMMEDIATE_COMMANDLISTS=0
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export CCL_TOPO_P2P_ACCESS=0

vllm serve ${MODEL} \\
  --served-model-name qwen25-coder-14B \\
  --port ${PORT} \\
  --host 0.0.0.0 \\
  --dtype bfloat16 \\
  --quantization fp8 \\
  --enforce-eager \\
  --attention-backend TRITON_ATTN \\
  --disable-custom-all-reduce \\
  --tensor-parallel-size 1 \\
  --gpu-memory-util 0.85 \\
  --block-size 64 \\
  --max-model-len 32768 \\
  --max-num-seqs 8 \\
  --enable-chunked-prefill \\
  --no-enable-prefix-caching \\
  --trust-remote-code \\
  2>&1 | tee -a /tmp/vllm_coder.log
"
echo "Qwen3-Coder-30B starting on port ${PORT} (TP=1, card 0)..."
