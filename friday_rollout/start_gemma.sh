#!/usr/bin/env bash
# =============================================================================
# start_gemma.sh — Tier 1 general-purpose LLM: Gemma 4 26B-A4B (FP8)
# Cards: 1,3 (TP=2)   Port: 8000   Container: vllm-b70-gemma
#
# This is the verified-working config from 2026-04-09 debugging session.
# See friday_rollout/README.md for the full story on why each flag exists.
#
# With 128GB RAM and no swap, try removing `--num-gpu-blocks-override 400`
# and ramping `--max-num-seqs` up past 4 after a successful first launch.
# =============================================================================
set -e
CONT=vllm-b70-gemma
MODEL=/llm/models/gemma-4-26B-A4B-it
PORT=8000

if ! docker ps --format '{{.Names}}' | grep -q "^${CONT}$"; then
    echo "ERROR: Container ${CONT} is not running."
    exit 1
fi
if curl -sf --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "Gemma already healthy on port ${PORT} — skipping start"
    exit 0
fi

docker exec -d "${CONT}" bash -c "
export ZE_AFFINITY_MASK=1,3
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export UR_L0_USE_IMMEDIATE_COMMANDLISTS=0
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export CCL_TOPO_P2P_ACCESS=0

vllm serve ${MODEL} \\
  --served-model-name gemma-4-26B-A4B \\
  --port ${PORT} \\
  --host 0.0.0.0 \\
  --dtype bfloat16 \\
  --quantization fp8 \\
  --enforce-eager \\
  --skip-mm-profiling \\
  --language-model-only \\
  --attention-backend TRITON_ATTN \\
  --disable-custom-all-reduce \\
  --tensor-parallel-size 2 \\
  --gpu-memory-util 0.85 \\
  --block-size 64 \\
  --max-model-len 32768 \\
  --max-num-seqs 4 \\
  --num-gpu-blocks-override 400 \\
  --enable-auto-tool-choice \\
  --tool-call-parser gemma4 \\
  --enable-chunked-prefill \\
  --no-enable-prefix-caching \\
  --trust-remote-code \\
  --chat-template ${MODEL}/chat_template.jinja \\
  2>&1 | tee -a /tmp/vllm_gemma.log
"
echo "Gemma 4 starting on port ${PORT} (TP=2, cards 1,3)..."
