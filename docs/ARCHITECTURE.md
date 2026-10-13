# Clipper Architecture

## Principles
1. **One timeline document drives everything.** A template is a partial timeline with slots. Automation is a pure function that produces a `Sequence`. A manual edit is an `EditCommand` of the form `(Sequence) -> Sequence`. Rendering turns a `Sequence` into pixels.
2. **Preview equals export.** One Metal compositor renders frames for AVPlayer preview and for AVAssetWriter export. Text and captions are drawn by that same compositor.
3. **Local-first, with optional extras.** The core runs on Apple frameworks only. ML models and the Python worker are downloaded only when you turn on the feature that needs them.
4. **Deterministic automation.** Draft passes are pure and seeded, so the CLI and the app produce identical drafts.

## Modules
One Xcode workspace: the app target plus a local package `Packages/ClipperKit`.

```
ClipperCore        Foundation only: model, RationalTime, Param<T>, templates, commands, migrations
ClipperAutomation  Core: pure draft passes
ClipperEngine      Core + AVFoundation/Metal/CoreText: import, proxies, composition, compositor, export, loudness
ClipperAnalysis    Core + Engine: Analyzer protocol, job scheduler, Speech/Vision/SoundAnalysis/MLX, worker client
ClipperLibrary     Core + GRDB: .clipperlib bundle, index, project I/O, settings, jobs, watch folders
ClipperApp         SwiftUI shell + AppKit timeline
clipper-cli        import | analyze | draft | export | batch (same engine, no UI)
worker/            uv Python project, JSON-RPC 2.0 over stdio (beat_this, librosa, PySceneDetect, ACE-Step)
```

## Library bundle
```
MyLibrary.clipperlib/
  index.sqlite                      GRDB, WAL mode; assets, analysis index, jobs, project index, settings
  Projects/<uuid>.clipproj.json     atomic writes, 10 rolling backups
  Media/                            copied-in originals (leave-in-place assets store bookmark + path)
  Proxies/<assetKey>/proxy.mov
  Cache/<assetKey>/<analyzer>@<ver>.json|.bin, thumbs/, peaks.bin
  Templates/                        user templates (built-ins ship inside the app bundle)
```
- `assetKey` is SHA-256 of (file size + the first, middle and last 4 MB + duration). It is fast to compute even on a 3-hour VOD, and it is used to re-link media left in place.
- Analysis results are cached by `(assetKey, analyzerID@version)`. Bumping an analyzer's version invalidates only that analyzer's cached results.

## Core model (summary)
```swift
struct RationalTime { value: Int64; scale: Int32 }            // converts to/from CMTime in the Engine
struct Sequence { canvas: Canvas; tracks: [Track]; provenance: Provenance? }
struct Track    { id; kind: .video|.audio|.music|.title|.overlay|.caption(info); items: [Item]; muted; locked; volume: Param<Double> }
struct Item     { id; timeline: TimeRange; content: .media(asset, source, speed)|.text|.image|.solid|.captionRun
                  transform: Transform (normalized, Param-keyframed); opacity; volume; fadeIn/Out
                  origin: .user | .auto(pass), locked }
enum Param<T>   { .constant(T) | .keyframes([Keyframe<T>]) }   // keyframe time is relative to the item
struct Template { id; version; contentType; canvas; skeleton: [Track]; slots: [Slot]; rules: [Rule]; styles; music; exportPreset }
enum Rule       { maxDuration, silenceCut, cutOnBeats, punchIn, reframe, duck, captions, loudnessTarget }
```
- **Undo:** `EditHistory` stores a snapshot of the `Sequence` before each command and registers it with `NSUndoManager`. Undo restores the snapshot, so there is no hand-written inverse logic. "Apply Draft" is a single command.
- **Re-drafting:** re-running the draft replaces only items whose origin is `.auto` and which are unlocked.

## Rendering pipeline
1. **CompositionBuilder** turns a `Sequence` plus a `MediaResolver` (proxy, mezzanine or original file) into an `AVMutableComposition`, an `AVVideoComposition` and an `AVAudioMix`. Overlapping items are placed on alternating A/B composition tracks.
2. **Instructions**: the timeline is split wherever the set of active layers changes. Each `ClipperInstruction` carries a `RenderGraph`, a list of layers with `Param` transforms that are evaluated per frame.
3. **ClipperCompositor** (`AVVideoCompositing`) works on `CVMetalTextureCache` textures.
   - HDR sources arrive **untouched** as half-float BT.2020 HLG/PQ. The composition is given the source's native HDR space; see ADR 0006 for why Apple's automatic conversion isn't used.
   - The shader tone-maps HDR with fitted luminance curves, then applies transform, crop and blend. Output buffers are tagged Rec.709.
   - Text is rendered with Core Text into a cached texture (per line and highlighted word) and animated with shader uniforms.
4. **Preview**: `AVPlayer` + `AVPlayerItem(videoComposition:)`. Rebuilds are debounced. Seeks use zero tolerance while paused.
5. **Export**: `AVAssetReaderVideoCompositionOutput` + `AVAssetReaderAudioMixOutput`, then a DSP stage (gain and true-peak limiter for the loudness target), then `AVAssetWriter`. Supports H.264, HEVC, HEVC with alpha, ProRes 422 and ProRes 4444.
6. **Variable frame rate**: the compositor pulls frames on the sequence's fixed frame interval. Proxies are written at a constant frame rate.
7. **Proxies are optional.** Frame-accurate seeks on 1080p60 HEVC originals take about 28 ms on an M4 Pro.
   - Created only for 4K, 10-bit HDR, or heavy multi-layer sequences.
   - Format: HEVC 720p, a keyframe every 0.5 s, no B-frames.
   - Generation is limited by **decoding** (about 400 fps for 1080p HEVC).
8. **One decode per source at ingest.** A single decode pass feeds thumbnails, waveform peaks, scene and face detection, and the proxy writer. Each analyzer doesn't re-decode.
9. **One hardware-encode scheduler.** All VideoToolbox encodes (exports, proxies, mezzanines) go through one queue, and exports jump ahead of queued background jobs (a background encode already running finishes first; it does not pause mid-way). Two concurrent HEVC sessions on the M4 Pro slow the foreground job by about 35×.
10. **Import fallback**: if AVFoundation can't play a file, FFmpeg transcodes it once to a 10-bit HEVC mezzanine file.

## Automation (first milestone)
Ingest → probe → mezzanine/proxy → analysis jobs (transcript, speechActivity, loudness, faces, beats) → draft passes:

| # | Pass | Summary |
|---|---|---|
| 1 | InstantiateSkeleton | Fill template slots by role and order |
| 2 | SilenceCut | **Snap word edges to voice activity first.** Transcriber end times run 130–500 ms early. Use the RMS envelope for clean audio, Silero VAD for noisy. Then cut gaps longer than minGap, pad 80/120 ms, and drop fillers (transcribed fillers plus voiced audio with no word) |
| 3 | FitDuration | Drop the segments with the fewest words per second until under maxDuration |
| 4 | PickMusic | Score by mood + BPM range + length fit; end on a phrase or downbeat; add CC attribution |
| 5 | BeatSnap | Move cut points to the nearest beat (never inside speech) |
| 6 | Captions | Group words into lines and apply a style preset |
| 7 | PunchIns | Zoom keyframes (1.0 → 1.15) on emphasis, with minimum spacing |
| 8 | Reframe | Face track → spring-smoothed crop keyframes, simplified with Ramer–Douglas–Peucker |
| 9 | Duck | Volume ramps on music under speech (−12 dB, 150 ms attack, 400 ms release) |
| 10 | LoudnessTarget | Applied at export |

## Concurrency
- Swift 6 strict concurrency throughout.
- Compositor instructions are immutable and `Sendable`.
- Caches live in actors.
- Metal objects sit in audited `@unchecked Sendable` wrappers.
- The analysis scheduler is an actor with a concurrency limit per resource (ANE, GPU, CPU).

## Long recordings → many shorts (Phase 2)
1. **Analysis.** `AnalysisPipeline` runs these kinds:
   - `speech` + `transcript`: streaming SpeechTranscriber. Word edges are snapped to voice activity.
   - `events`: SoundAnalysis classifier v1. Laughter, applause, cheering, shouting, crowd, booing and gasp labels are merged into events.
   - `visual`: about 1 sample per second from keyframe-near frames (AVAssetImageGenerator with tolerance, 256 px). Measures colour-histogram plus pixel change, adaptive scene cuts, and a Vision attention-saliency box.

   Results are cached by content key, so re-running is instant.
2. **Candidates** (`HighlightFinder`, pure):
   - Windows start and end on sentence boundaries (20–60 s by default).
   - Each window is scored on named signals: hook, completeness, pacing, energy/peaks, payoff (sound events weighted towards the end), visual action and length fit, minus fillers and dead air.
   - Recordings without speech fall back to windows anchored on scene cuts.
   - Greedy selection keeps the best non-overlapping windows.
3. **Optional re-ranking** (`LocalLLMRanker`, ADR 0007):
   - Uses an OpenAI-compatible server on localhost only. Cloud-tagged models and non-loopback hosts are refused.
   - Final score = 0.6 × LLM score + 0.4 × heuristic score.
   - Adds a hook title per candidate.
4. **Drafting.** Each picked highlight becomes `ClipInput(inPoint:outPoint:)` → `DraftPipeline`, the same path as Phase 1. A project holds one timeline per short. Export runs as a batch.
5. **Reframing.** Slots follow faces, or the salient region when there are no faces. Gameplay and montage reframe by saliency.
6. **Automation hooks.**
   - `clipper highlights`: list, `--draft`, `--export`.
   - `clipper watch <folder>`: processes a file once its size is stable.

**Audio decoding rule:** decode at the native sample rate and convert with `Resampler`. AVAssetReader's own resampling inserts clicks.

## Caption sidecars and translation
- **Sidecars** (`Subtitles.sidecars`, written by the Exporter for the preset's `sidecars`):
  - `<name>.srt|vtt|ass` holds the **visible** caption tracks, i.e. what is burned in.
  - `<name>.<language>.srt|vtt|ass` is written for every caption track with a `Track.language`, **including hidden ones**.
  - Drafts tag their caption track with the transcript's language.
- **ASS** keeps the styling: font (Core Text full name), size × canvas height, colours as `&HAABBGGRR` (alpha inverted), outline/box/shadow, alignment and margins from `position`/`maxWidth`.
  - The active-word highlight becomes `\k` karaoke. Because `\k` keeps a word in `PrimaryColour` once it is reached, karaoke styles put the highlight colour in `PrimaryColour` and the text colour in `SecondaryColour`.
  - Each word also carries a `\t` that turns it back to its own colour when the next word starts, so only the spoken word is highlighted, as in the renderer.
- **Translation** (`CaptionTranslator`, Apple Translation, on-device, installed pairs only):
  - Each page is translated whole. Words are spread over the source words' time span in proportion to their length, and page timing is kept.
  - The result is a hidden `Captions (<lang>)` track placed after the source. IDs are derived from the source ID and the language, so re-running replaces the track.
  - Chinese, Japanese and Thai are cut into short phrases at punctuation and `NLTokenizer` word boundaries, and sidecars join them without spaces.
  - Right-to-left pages are laid out right to left by `TextRenderer`.
