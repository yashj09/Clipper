#!/usr/bin/env bash
# Builds Fixtures/vod_30min.mov: the 30-min 1080p60 HEVC test footage with 30 minutes of narrated "stream talk"
# (macOS `say`), for benchmarking highlight detection on long recordings (Phase 2 exit test).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -s Fixtures/long_30min_1080p60.mov ]] || ./scripts/make-fixtures.sh >/dev/null
OUT=Fixtures/vod_30min.mov
[[ -s $OUT ]] && { echo "$OUT exists"; exit 0; }
TMP=$(mktemp -d)
python3 - "$TMP/script.txt" <<'PY'
import random, sys
random.seed(7)
openers = ["So", "Okay so", "Alright", "Now", "Honestly", "Right", "And then"]
topics = ["the boss fight", "this build", "the new map", "my settings", "the patch notes", "ranked mode", "the speedrun route",
          "the loot table", "this weapon", "the final level", "the community challenge", "my keyboard", "the update"]
bodies = ["is way better than people think", "completely changed how I play", "has a problem nobody talks about",
          "took me about {n} hours to figure out", "is the reason I almost quit", "saves you {n} minutes every run",
          "breaks if you jump right here", "is honestly the best part of the game", "made the chat go crazy last week"]
hooks = ["Why does nobody use {t}?", "Here's the secret about {t}.", "Wait, did you know {t} {b}?",
         "This is the biggest mistake people make with {t}.", "Stop doing this with {t}!"]
fill = ["um let me check something", "uh hold on", "where was I", "let me read chat real quick", "okay give me a second"]
lines = []
for i in range(520):
    t, b = random.choice(topics), random.choice(bodies).replace("{n}", str(random.randint(2, 40)))
    r = random.random()
    if r < 0.08:
        lines.append(random.choice(hooks).replace("{t}", t).replace("{b}", b) + " [[slnc 900]]")
    elif r < 0.16:
        lines.append(random.choice(fill) + ". [[slnc 2500]]")
    else:
        lines.append(f"{random.choice(openers)} {t} {b}. [[slnc {random.choice([300, 500, 800, 1200])}]]")
open(sys.argv[1], "w").write("\n".join(lines))
PY
say -v Samantha -r 175 -f "$TMP/script.txt" -o "$TMP/speech.aiff"
ffmpeg -hide_banner -loglevel error -y -i Fixtures/long_30min_1080p60.mov -i "$TMP/speech.aiff" \
  -map 0:v -map 1:a -c:v copy -c:a aac -b:a 128k -shortest "$OUT"
rm -rf "$TMP"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT"
