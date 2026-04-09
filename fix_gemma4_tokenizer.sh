#!/usr/bin/env bash
# =============================================================================
# fix_gemma4_tokenizer.sh — Convert Gemma 4 tokenizer.json merges to legacy format
#
# Gemma 4's tokenizer.json uses the new [[token_a, token_b], ...] list-form
# merges. The Rust tokenizers 0.22.2 shipped in intel/vllm 0.17.0-xpu has
# multiple parse bugs when handling this on the BPE init + unpickle code
# paths, producing errors like:
#   - "data did not match any variant of untagged enum MergeType"
#   - "Token ,[ out of vocabulary at line 2322064 column 1"
#   - "Token Hybrid out of vocabulary at line 1 column 13593370"
#
# Converting merges to the legacy "a b" space-joined string format bypasses
# the MergeType untagged enum entirely. This is safe because no Gemma 4 merge
# token contains a space (verified across all 514,906 merges).
#
# Idempotent — re-running is a no-op if merges are already legacy format.
# Creates tokenizer.json.bak.listmerges on first run.
# =============================================================================
set -euo pipefail

MODEL_PATH="${1:-/home/brendanhouck/models/gemma-4-26B-A4B-it}"
TOK="${MODEL_PATH}/tokenizer.json"

if [[ ! -f "$TOK" ]]; then
    echo "ERROR: tokenizer.json not found at $TOK"
    echo "Usage: $0 [/path/to/model-dir]"
    exit 1
fi

if [[ ! -f "${TOK}.bak.listmerges" ]]; then
    cp "$TOK" "${TOK}.bak.listmerges"
    echo "[+] Backup saved to ${TOK}.bak.listmerges"
fi

python3 - << PYTOK
import json, sys
p = "$TOK"
d = json.load(open(p))
m = d.get("model", {}).get("merges", [])
if not m:
    print("[!] No merges found in tokenizer.json — nothing to do")
    sys.exit(0)
if not isinstance(m[0], list):
    print(f"[+] Already legacy format ({len(m)} merges), skipping")
    sys.exit(0)
# Safety check: no merge should contain a space in either token
bad = [(i, x) for i, x in enumerate(m) if isinstance(x, list) and len(x) == 2 and (" " in x[0] or " " in x[1])]
if bad:
    print(f"[!] ERROR: {len(bad)} merges contain spaces in their tokens;")
    print(f"    legacy format would be ambiguous. First offender: merge {bad[0][0]} = {bad[0][1]!r}")
    sys.exit(1)
new = [(x[0] + " " + x[1]) if isinstance(x, list) and len(x) == 2 else x for x in m]
d["model"]["merges"] = new
json.dump(d, open(p, "w"), ensure_ascii=False)
print(f"[+] Converted {len(m)} merges from list to legacy string format")
PYTOK

echo "[+] Done. Restart vLLM for the change to take effect."
