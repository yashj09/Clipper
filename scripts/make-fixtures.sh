#!/usr/bin/env bash
# Generates synthetic Phase 0 fixtures with known ground truth into Fixtures/.
# Needs: ffmpeg (VideoToolbox), macOS `say`, python3. Re-running is safe; existing files are skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Fixtures
mkdir -p "$OUT/tmp"
LONG_MIN="${LONG_MIN:-30}"   # length of the long-media fixture, in minutes

have() { [[ -s "$OUT/$1" ]]; }
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# --- S1: compositor parity -------------------------------------------------------------
# Vertical 60 fps background with a burned-in frame counter (testsrc2) plus a 1 kHz tone.
have bg_1080x1920_60.mov || ff \
  -f lavfi -i "testsrc2=s=1080x1920:r=60:d=10" -f lavfi -i "sine=f=1000:d=10:sample_rate=48000" \
  -c:v hevc_videotoolbox -q:v 75 -tag:v hvc1 -g 60 -c:a aac -b:a 128k "$OUT/bg_1080x1920_60.mov"
# Landscape 30 fps overlay (different size and frame rate) for picture-in-picture; testsrc burns in a counter.
have overlay_1280x720_30.mov || ff \
  -f lavfi -i "testsrc=s=1280x720:r=30:d=10,hue=h=140:s=1.4" \
  -c:v h264_videotoolbox -q:v 75 -g 30 "$OUT/overlay_1280x720_30.mov"

# --- S2: HDR -------------------------------------------------------------------------------
# 10-bit HEVC tagged as BT.2020 HLG / PQ. Top half: colour test pattern at moderate signal levels.
# Bottom half: a black→full-scale signal ramp, so the highlights exercise the tone-mapping roll-off.
# Built in RGB (gbrp) so no chroma corruption, then converted to 10-bit 4:2:0.
# Drop real iPhone HDR clips into Fixtures/user/ for a visual check.
for trc in hlg pq; do
  case $trc in hlg) T=arib-std-b67 ;; pq) T=smpte2084 ;; esac
  have "hdr_${trc}_10bit.mov" || ff \
    -f lavfi -i "testsrc2=s=1920x540:r=30:d=5,format=gbrp" \
    -f lavfi -i "gradients=s=1920x540:r=30:d=5:c0=black:c1=white:x0=0:y0=270:x1=1919:y1=270:speed=0,format=gbrp" \
    -filter_complex "[0:v][1:v]vstack,format=p010le,setparams=color_primaries=bt2020:color_trc=$T:colorspace=bt2020nc:range=tv" \
    -c:v hevc_videotoolbox -profile:v main10 -q:v 80 -tag:v hvc1 \
    -color_primaries bt2020 -color_trc "$T" -colorspace bt2020nc \
    "$OUT/hdr_${trc}_10bit.mov"
done

# --- S3: speech-to-text --------------------------------------------------------------------
# Scripted sentences (some with filler words), each trimmed to speech, joined with known gaps.
# Ground truth (text + sentence boundaries) goes to speech_truth.json.
if ! have speech_clean.wav; then
  VOICE="${VOICE:-Samantha}"; say -v "$VOICE" "test" -o "$OUT/tmp/v.aiff" 2>/dev/null || VOICE="Eddy (English (US))"
  python3 - "$OUT" "$VOICE" <<'PY'
import json, subprocess, sys, os
out, voice = sys.argv[1], sys.argv[2]
sentences = [
  "Welcome back to the channel, today we are testing an automatic video editor.",
  "Um, so the first thing you need to know is that everything runs locally on your Mac.",
  "There are no subscriptions and no cloud uploads.",
  "Uh, let me show you how the captions line up with each word.",
  "If the timing is off by more than a few frames, viewers will notice immediately.",
  "We also want to remove long pauses automatically.",
  "Like, you know, the awkward silence after a joke that did not land.",
  "Finally, the music should duck under my voice and come back up between sentences.",
]
gaps = [0.6, 1.4, 0.35, 2.0, 0.5, 1.1, 0.8]
segs, t, truth = [], 0.0, []
for i, s in enumerate(sentences):
    a, w = f"{out}/tmp/s{i}.aiff", f"{out}/tmp/s{i}.wav"
    subprocess.run(["say", "-v", voice, "-o", a, s], check=True)
    # Trim leading and trailing silence so the segment boundaries equal the speech boundaries.
    subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-y","-i",a,"-af",
        "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse",
        "-ar","16000","-ac","1",w], check=True)
    d = float(subprocess.check_output(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",w]))
    truth.append({"text": s, "start": round(t,3), "end": round(t+d,3)})
    segs.append(w); t += d
    if i < len(gaps):
        g = f"{out}/tmp/g{i}.wav"
        subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-y","-f","lavfi","-i",
            f"anullsrc=r=16000:cl=mono","-t",str(gaps[i]),g], check=True)
        segs.append(g); t += gaps[i]
with open(f"{out}/tmp/list.txt","w") as f:
    f.writelines(f"file '{os.path.abspath(p)}'\n" for p in segs)
subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-y","-f","concat","-safe","0","-i",f"{out}/tmp/list.txt",
    "-ar","16000","-ac","1","-c:a","pcm_s16le",f"{out}/speech_clean.wav"], check=True)
json.dump({"voice": voice, "duration": round(t,3), "gaps": gaps, "sentences": truth},
          open(f"{out}/speech_truth.json","w"), indent=2)
PY
fi
# Noisy variant: speech plus pink noise and a "game music" chord about 18 dB down.
have speech_noisy.wav || ff -i "$OUT/speech_clean.wav" \
  -f lavfi -i "anoisesrc=color=pink:amplitude=0.05:sample_rate=16000" \
  -f lavfi -i "sine=f=220:sample_rate=16000,volume=0.08" -f lavfi -i "sine=f=330:sample_rate=16000,volume=0.06" \
  -filter_complex "[0:a][1:a][2:a][3:a]amix=inputs=4:duration=first:normalize=0" -ac 1 "$OUT/speech_noisy.wav"

# --- S5: long media ------------------------------------------------------------------------
# 1080p60 HEVC with a 2 s GOP, like a typical OBS or phone recording, plus stereo audio.
have "long_${LONG_MIN}min_1080p60.mov" || ff \
  -f lavfi -i "testsrc2=s=1920x1080:r=60:d=$((LONG_MIN*60))" -f lavfi -i "sine=f=440:sample_rate=48000:d=$((LONG_MIN*60))" \
  -c:v hevc_videotoolbox -b:v 12M -tag:v hvc1 -g 120 -c:a aac -b:a 128k -ac 2 \
  "$OUT/long_${LONG_MIN}min_1080p60.mov"

rm -rf "$OUT/tmp"
ls -lh "$OUT"
