#!/usr/bin/env bash
# End-to-end check of the CLI: fixture "talking head" clip → draft → export, verified with ffprobe + ebur128, then
# the same clip as a vlog, whose short pauses play fast and whose export must be as long as its timeline.
# Uses a scratch library in $TMPDIR so your real library is untouched.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
[[ -s Fixtures/speech_clean.wav ]] || ./scripts/make-fixtures.sh >/dev/null

WORK=$(mktemp -d "${TMPDIR:-/tmp}/clipper-e2e.XXXX")
LIB="$WORK/E2E.clipperlib"
CLI="$ROOT/Packages/ClipperKit/.build/release/clipper"
(cd Packages/ClipperKit && swift build -c release --product clipper >/dev/null)

# A 1080x1920 "talking head": moving test pattern with the scripted speech as its audio.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=1080x1920:r=30" -i Fixtures/speech_clean.wav \
  -shortest -c:v h264_videotoolbox -q:v 60 -c:a aac -b:a 160k "$WORK/talk.mov"

echo "== draft + export (talking-head)"
"$CLI" draft --library "$LIB" -t talking-head --title "E2E test" "$WORK/talk.mov" --no-music --export -o "$WORK/out.mp4"

echo "== draft + export (vlog)"
"$CLI" draft --library "$LIB" -t vlog --title "E2E vlog" "$WORK/talk.mov" --no-music --export -o "$WORK/vlog.mp4" | tee "$WORK/vlog.log"

echo "== verify"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,codec_name -show_entries format=duration -of compact "$WORK/out.mp4"
SRC=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/talk.mov")
OUT=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/out.mp4")
LUFS=$(ffmpeg -hide_banner -nostats -i "$WORK/out.mp4" -af ebur128 -f null - 2>&1 | awk '/I:/{v=$2} END{print v}')
echo "source ${SRC}s → draft ${OUT}s, integrated ${LUFS} LUFS"
VLOG=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/vlog.mp4")
python3 - "$SRC" "$OUT" "$LUFS" "$WORK/out.srt" "$VLOG" "$WORK/vlog.log" <<'PY'
import sys, os, re
src, out, lufs, srt = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
vlog, log = float(sys.argv[5]), open(sys.argv[6]).read()
ok = True
def check(cond, msg):
    global ok
    print(("PASS " if cond else "FAIL ") + msg); ok &= cond
check(out < src - 3, f"pauses removed ({src:.1f}s → {out:.1f}s)")
check(abs(lufs - -14) <= 1.0, f"loudness {lufs} LUFS within ±1 of -14")
check(os.path.exists(srt) and "editor" in open(srt).read().lower(), "SRT sidecar with transcript")
sped = re.search(r"Sped up (\d+) pauses", log)
check(sped is not None and int(sped.group(1)) > 0, f"vlog: {sped.group(0) if sped else 'no pauses sped up'}")
drafted = float(re.search(r"Draft: ([0-9.]+)s", log).group(1))
check(abs(vlog - drafted) <= 0.1, f"vlog: export {vlog:.2f}s matches the {drafted:.1f}s timeline")
sys.exit(0 if ok else 1)
PY
echo "Artifacts in $WORK"
