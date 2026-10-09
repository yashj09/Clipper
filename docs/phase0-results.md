# Phase 0 results: de-risking spikes (2026-10-10)

Machine: Apple M4 Pro, 24 GB, macOS 27.0, Swift 6.2.3 (Command Line Tools only; Metal shaders compiled at runtime).
Reproduce:
```
scripts/make-fixtures.sh
cd Spikes && swift build -c release
.build/release/s1-parity     # add `codecs` for the codec diagnostics
.build/release/s2-hdr
.build/release/s3-asr && scripts/run_whisper.sh && SNAP_MARGIN_DB=3 python3 scripts/eval_asr.py
.build/release/s4-timeline   # opens a window for ~8 s
.build/release/s5-longmedia
```
Each spike writes its results to `Spikes/out/<spike>/result.json`.

## Summary

| Spike | Verdict | Key numbers | Decision |
|---|---|---|---|
| S1 preview/export parity | ✅ | Composited frames from AVPlayer and from export are **bit-identical (20/20)**. ProRes 4444 master: 53.8 dB. Playback at 60 fps: 0% dropped. Export: ProRes 300 fps, HEVC 215 fps. | One Metal compositor for preview and export works (ADR 0003 confirmed). |
| S2 HDR → SDR | ✅ (synthetic) | **Apple's automatic HLG conversion differs between preview and export (18–20 dB).** Our shader is bit-identical between them, with ≈29 dB agreement against Apple's look. | **We do our own tone mapping** (new ADR 0006). |
| S3 Speech-to-text | ✅ clean / ⚠️ noisy | Apple: WER 1%, 48–64× realtime. Raw end timestamps are 275 ms early. **After loudness snapping: 5 ms median error on clean speech; 31 ms median / 280 ms p90 on noisy.** whisper-turbo: WER 0%, keeps fillers, but loose timing and 9× realtime. | Apple SpeechTranscriber is primary, with boundary snapping. Silero VAD for noisy audio. whisper.cpp optional for caption text. |
| S4 Timeline UI | ✅ | **120 fps with 0–0.3% long frames.** 8 tracks, 2,000 items. Update cost p50 0.45 ms, p99 5–6 ms (stretch goal was 4 ms). | AppKit + CALayer with virtualization and level of detail. Metal is not needed. |
| S5 Long media | ✅ seek / ❌ proxy speed | Seek on the **original** 1080p60 HEVC: 28 ms median. Seek on the proxy: 4 ms. Proxy generation 6.5× realtime, **limited by decoding** (VideoToolbox decodes ≈330–430 fps for 1080p60). | Proxies are optional and made in the background. **Decode each source once** and feed every analyzer from it. |

## Findings that change the design

1. **HDR: don't use AVFoundation's automatic conversion** (S2).
   - With HLG sources, the AVPlayer and AVAssetReader paths tone-map differently.
   - Fix: give the composition the source's native HDR colour space, so the compositor receives untouched `RGhA` half-float BT.2020 HLG/PQ frames. Then tone-map in our shader and tag the output buffers as Rec.709 ourselves.
   - Fitted curves (luminance-based, which preserves hue):
     - HLG: `Y_sdr = Y_scene^0.654`
     - PQ: `x = nits/180; Y_sdr = (x(1 + x/2.25)/(1 + x))^0.7`
   - These match Apple's own SDR rendering of a signal ramp within 2–3/255 RMSE.
   - Gotcha: AVFoundation converts frames to the *composition* colour space even when `supportsHDRSourceFrames` is true.
   - Gotcha: when FFmpeg runs a filtergraph, it drops `-color_trc` output flags. Use `setparams`.
2. **Schedule hardware encodes through one queue** (S1).
   - While another HEVC encode is running, our HEVC export falls from 210 fps to **6 fps** (the M4 Pro has one encode engine).
   - Proxy, mezzanine and export jobs need a single scheduler, and background work pauses during an export.
3. **Decoding is the scarce resource for long media** (S5).
   - Ingest should decode each source **once** and fan the frames out to thumbnails, waveforms, scene and face detection, and the optional proxy, instead of each analyzer decoding separately.
   - A 30-minute 60 fps VOD takes about 4.6 minutes per full decode pass.
4. **Proxies are optional for 1080p** (S5). Frame-accurate seeks on originals take about 28 ms. Create proxies automatically only for 4K, 10-bit HDR, or heavy multi-layer sequences.
5. **ASR timestamps need refining before cuts** (S3).
   - SpeechTranscriber is accurate on words but ends sentences 130–500 ms *early*, which would clip speech.
   - Snapping word edges to the RMS envelope (10 ms frames; extend up to 600 ms; threshold = noise floor + 3 dB) fixes clean audio.
   - Noisy audio needs a real VAD. Apple's `SpeechDetector` returned no results in file mode; Silero VAD (MIT) is the plan.
   - SpeechTranscriber drops some fillers ("Uh") and writes "1st" for "first". Find fillers as *voiced audio with no word* as well.
6. **Delivery codecs and PSNR** (S1). 4:2:2 and 4:2:0 codecs score 33–37 dB on synthetic saturated patterns from chroma subsampling alone; the mean colour shift is ≈0. Judge parity on 4:4:4 masters; judge delivery codecs on real footage.
7. **Timeline performance** (S4).
   - Virtualize item layers with a reuse pool.
   - Switch to per-track summary strips when an average item is under 16 px wide.
   - Let `autoresizingMask` resize sub-layers.
   - Touch `contents` only when it changes.
   - Keeping pooled layers in the tree but hidden was *slower* than removing them.

## Smaller notes for Phase 1
- `AVPlayerItem` is `@MainActor` in the macOS 26 SDK. Swift 6 strict concurrency with AVFoundation works using `Unchecked<T>` wrappers and `isolation:` parameters.
- Captions need line wrapping within a title-safe area; the spike's single-line caption ran off the frame.
- iPhone clips carry rotation in `preferredTransform`, which the custom compositor must apply. The spike fixtures have none.
- Text from Core Text → MTLTexture, cached per (line, highlighted word), gives word-by-word highlighting cheaply.
- Homebrew FFmpeg has no `drawtext` or `zscale` (no freetype or zimg). That's fine, since FFmpeg is only a development tool and import fallback.

## Real iPhone footage (S2 follow-up)
`Fixtures/user/IMG_4148.MOV`: HEVC Main10, **Dolby Vision profile 8 (HLG base)**, **rotation −90°**, **variable frame rate** (29.55 fps average).
- Apple's automatic conversion, preview vs export: **7–14 dB** (far worse than on synthetic clips). Confirms ADR 0006.
- Our path, preview vs export: **bit-identical** on all samples.
- Ours vs Apple: 25–28 dB. Ours is about 0.03 brighter in mean and a little lower in contrast. Visually natural, with highlights intact. Could expose this later as a "tone mapping strength" setting.
- Rotation is not applied by the spike compositor (frames come out sideways). **Phase 1 must apply the track's `preferredTransform`.**
- The Dolby Vision RPU metadata is ignored; we tone-map from the HLG base layer, which is the intended fallback for profile 8.4.

## Still open
- [x] Visual check of the HDR tone mapping on **real iPhone HDR footage** (see above).
- [ ] S3 on **real recorded speech** (your voice, game audio underneath) with hand-checked boundaries. TTS fixtures are optimistic.
- [ ] Install Xcode, needed for the Phase 1 app target and for Instruments profiling.
