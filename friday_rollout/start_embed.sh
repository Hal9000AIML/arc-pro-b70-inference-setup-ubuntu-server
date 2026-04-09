#!/usr/bin/env bash
# =============================================================================
# start_embed.sh — Embedding model: Qwen3-Embedding-4B
# Card: 2 (shared with Qwen3-8B fast tier)    Port: 8003
# Container: vllm-b70-embed
#
# Small footprint (4B params), co-resident with Qwen3-8B on card 2.
# Replaces nomic-embed-text in the RAG pipeline.
# =============================================================================
set -e
CONT=vllm-b70-embed
MODEL=/llm/models/Qwen3-Embedding-4B
PORT=8003

if ! docker ps --format '{{.Names}}' | grep -q "^${CONT}$"; then
    echo "ERROR: Container ${CONT} is not running."
    exit 1
fi
if curl -sf --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "Embed already healthy on port ${PORT} — skipping start"
    exit 0
fi

docker exec -d "${CONT}" bash -c "
export ZE_AFFINITY_MASK=2
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export UR_L0_USE_IMMEDIATE_COMMANDLISTS=0
export CCL_TOPO_P2P_ACCESS=0

vllm serve ${MODEL} \\
  --served-model-name qwen3-embed-4B \\
  --port ${PORT} \\
  --host 0.0.0.0 \\
  --dtype bfloat16 \\
  --task embed \\
  --enforce-eager \\
  --disable-custom-all-reduce \\
  --tensor-parallel-size 1 \\
  --gpu-memory-util 0.30 \\
  --trust-remote-code \\
  2>&1 | tee -a /tmp/vllm_embed.log
"
echo "Qwen3-Embedding-4B starting on port ${PORT} (TP=1, card 2 co-resident)..."
