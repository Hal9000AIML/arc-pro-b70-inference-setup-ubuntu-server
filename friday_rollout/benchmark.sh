#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — Sanity-check tok/s on all three vLLM backends after Friday rollout
# =============================================================================
set -e

check_endpoint() {
    local name=$1 port=$2 model=$3
    printf "\n== %-15s (port %d) ==\n" "$name" "$port"
    if ! curl -sf --max-time 3 "http://127.0.0.1:${port}/health" >/dev/null; then
        echo "  DOWN — skipping"
        return 1
    fi
    local t0 resp
    t0=$(date +%s.%N)
    resp=$(curl -s "http://127.0.0.1:${port}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a 100-word summary of quantum computing.\"}],\"max_tokens\":150,\"temperature\":0.3}")
    local t1=$(date +%s.%N)
    local ct=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['usage']['completion_tokens'])" 2>/dev/null || echo "?")
    local dur=$(python3 -c "print(f'{$t1 - $t0:.2f}')")
    local toks=$(python3 -c "print(f'{$ct / ($t1 - $t0):.1f}' if '$ct' != '?' else '?')")
    echo "  OK — ${ct} tokens in ${dur}s = ${toks} tok/s"
    echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print('  sample:', d['choices'][0]['message']['content'][:100].replace(chr(10), ' '))" 2>/dev/null || true
}

check_embed() {
    local name=$1 port=$2 model=$3
    printf "\n== %-15s (port %d) ==\n" "$name" "$port"
    if ! curl -sf --max-time 3 "http://127.0.0.1:${port}/health" >/dev/null; then
        echo "  DOWN — skipping"
        return 1
    fi
    local resp dim
    resp=$(curl -s "http://127.0.0.1:${port}/v1/embeddings" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${model}\",\"input\":\"Hello world\"}")
    dim=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['data'][0]['embedding']))" 2>/dev/null || echo "?")
    echo "  OK — embedding dim: ${dim}"
}

check_endpoint "gemma-4-26B"   8000 "gemma-4-26B-A4B"
check_endpoint "qwen3-coder"   8001 "qwen3-coder-30B"
check_endpoint "qwen3-8B"      8002 "qwen3-8B"
check_embed    "qwen3-embed"   8003 "qwen3-embed-4B"

echo
echo "Done. Expected ranges on 4x B70 + 128GB RAM:"
echo "  gemma-4-26B (TP=2):  15-25 tok/s"
echo "  qwen3-coder-30B:     20-35 tok/s"
echo "  qwen3-8B:            40-60 tok/s"
echo "  qwen3-embed-4B:      dim=2560"
