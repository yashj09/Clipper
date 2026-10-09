#!/usr/bin/env bash
# S3 (part 2): whisper.cpp word-level transcripts in Spikes/out/s3/<engine>__<fixture>.json (+ .meta with timing).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Spikes/out/s3; mkdir -p "$OUT"
run() { # engine model extra-args...
  local engine=$1 model=$2; shift 2
  for fx in speech_clean speech_noisy; do
    local t0=$(python3 -c 'import time;print(time.time())')
    whisper-cli -m "models/$model" -f "Fixtures/$fx.wav" -oj -ml 1 -sow -l en -np "$@" -of "$OUT/${engine}__${fx}" >/dev/null 2>&1
    python3 -c "import time,json;json.dump({'seconds':time.time()-$t0},open('$OUT/${engine}__${fx}.json.meta','w'))"
  done
}
run whisper-base ggml-base.en.bin
run whisper-base-dtw ggml-base.en.bin -dtw base.en
run whisper-turbo ggml-large-v3-turbo-q5_0.bin
run whisper-turbo-dtw ggml-large-v3-turbo-q5_0.bin -dtw large.v3.turbo
