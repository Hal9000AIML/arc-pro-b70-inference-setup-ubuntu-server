#!/usr/bin/env bash
# =============================================================================
# start_fast.sh — Tier 3 fast LLM: Qwen3-8B (FP8)
# Card: 2 (TP=1)    Port: 8002    Container: vllm-b70-fast
#
# Small/fast tier for simple queries. Shares card 2 with the embedding model
# (start_embed.sh), so KV cache is capped to leave room for the embedder.
# =============================================================================
set -e
CONT=vllm-b70-fast
MODEL=/llm/models/Qwen3-8B
PORT=8002

if ! docker ps --format '{{.Names}}' | grep -q "^${CONT}$"; then
    echo "ERROR: Container ${CONT} is not running."
    exit 1
fi
if curl -sf --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "Qwen3-8B already healthy on port ${PORT} — skipping start"
    exit 0
fi

docker exec -d "${CONT}" bash -c "
export ZE_AFFINITY_MASK=2
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export UR_L0_USE_IMMEDIATE_COMMANDLISTS=0
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export CCL_TOPO_P2P_ACCESS=0

vllm serve ${MODEL} \\
  --served-model-name qwen3-8B \\
  --port ${PORT} \\
  --host 0.0.0.0 \\
  --dtype bfloat16 \\
  --quantization fp8 \\
  --enforce-eager \\
  --attention-backend TRITON_ATTN \\
  --disable-custom-all-reduce \\
  --tensor-parallel-size 1 \\
  --gpu-memory-util 0.55 \\
  --block-size 64 \\
  --max-model-len 16384 \\
  --max-num-seqs 16 \\
  --enable-chunked-prefill \\
  --no-enable-prefix-caching \\
  --trust-remote-code \\
  2>&1 | tee -a /tmp/vllm_fast.log
"
echo "Qwen3-8B starting on port ${PORT} (TP=1, card 2)..."
