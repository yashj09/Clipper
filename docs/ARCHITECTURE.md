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
5. **Export**: `AVAssetReaderVideoCompositionOutput` + `AVAssetReaderAudioMixOutput`, then a DSP stage (gain and true-peak limiter for the loudness target), then `AVAssetWriter`. With a loudness target the composition is built once: the measuring pass captures the mixed PCM to a temporary CAF that the render pass streams back through the stage, so the audio is decoded and mixed once. Supports H.264, HEVC, HEVC with alpha, ProRes 422 and ProRes 4444.
6. **Variable frame rate**: the compositor pulls frames on the sequence's fixed frame interval. Proxies keep the original's sample timing (VFR stays VFR), so source times map identically.
7. **Proxies are optional** (`ProxyGenerator`). Frame-accurate seeks on 1080p60 HEVC originals take about 28 ms on an M4 Pro; on a proxy about 4 ms.
   - Made automatically for sources beyond 1080p, ProRes, and recordings over 20 minutes (`editing.proxyPolicy`: automatic / always / never), in the background after import and on launch.
   - Format: HEVC with a 720 px short side, a keyframe every second, no B-frames. Audio is copied untouched.
   - The original's preferred transform and colour tags are kept: the compositor keeps using the *original* asset's `MediaInfo` (rotation, transfer), so an HDR proxy stays 10-bit BT.2020 and an untagged source gets an untagged proxy (it then decodes with the same inferred matrix).
   - Generation is limited by **decoding**: 6.5× realtime for 1080p60 HEVC (30 min in 4.6 min). Stored in `Proxies/<assetKey>/proxy.mov`. A missing proxy file falls back to the original.
8. **One audio decode per source at analysis** (`AudioIngest`). Speech envelope, transcript (`PCMStreamTranscriber`), loudness and sound events share one native-rate decode; the 16 kHz branch uses `StreamingResampler` (bit-identical to `Resampler`). Cached kinds are resolved first, so only misses decode. Faces and visual activity keep their own video decodes: no workflow requests both (drafts want faces, highlights want visual activity). Measured: 30-min VOD highlights set 36.9 s → 31.2 s cold; the transcriber is the long pole.
9. **One hardware-encode scheduler.** All VideoToolbox encodes (exports, proxies, mezzanines) go through one queue, and exports jump ahead of queued background jobs (a background encode already running finishes first; it does not pause mid-way). Two concurrent HEVC sessions on the M4 Pro slow the foreground job by about 35×.
10. **Import fallback**: if AVFoundation can't play a file, FFmpeg transcodes it once to a 10-bit HEVC mezzanine file.

## Automation (first milestone)
Ingest → probe → mezzanine/proxy → analysis jobs (transcript, speechActivity, loudness, faces, beats) → draft passes:

| # | Pass | Summary |
|---|---|---|
| 1 | InstantiateSkeleton | Fill template slots by role and order |
| 2 | SpeechPlan | Per clip, in source time: drop stutters and restarts, keep one take of a repeated line (last complete or best) and mark it, tag kept words with emphasis cues. The cutter subtracts what it excludes |
| 3 | SilenceCut | **Snap word edges to voice activity first.** Transcriber end times run 130–500 ms early. The only voice-activity detector is the RMS envelope; noisy audio has no dedicated VAD yet, so its edges snap less accurately. Then cut gaps longer than minGap, pad 80/120 ms, and drop fillers (transcribed fillers plus voiced audio with no word). With `speedUp` (on in vlog), a cut pause up to `maxPause` (1.5 s) with no filler or edit in it is kept between the padded speech and played at `rate` (2.5x), so the footage runs on without a jump; fit drops these first and beat snapping and zoom steps leave them alone |
| 4 | FitDuration | Drop segments until under maxDuration, never the first. With an LLM brief scoring every sentence, speech is split at sentence boundaries first and the least important sentences go (ties to the least dense); without one, the segments with the fewest words per second go. Fast pauses always go before speech. Pieces that still play straight through are joined back into one item |
| 5 | PickMusic | Score by mood + BPM range + length fit; end on a phrase or downbeat; add CC attribution |
| 6 | BeatSnap | Move cut points to the nearest beat (never inside speech) |
| 7 | Captions | Group words into lines and apply a style preset |
| 8 | PunchIns | One zoom curve over the track. Cued words zoom in or out at least minSpacing apart, stepping on a cut just before them; a slow push fills any stretch over maxStill with no cut or zoom. No move straddles a cut |
| 9 | Reframe | Face track → spring-smoothed crop keyframes, simplified with Ramer–Douglas–Peucker |
| 10 | Duck | Volume ramps on music under speech (−12 dB, 150 ms attack, 400 ms release) |
| 11 | LoudnessTarget | Applied at export |

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
   - `visual`: about 1 sample per second from keyframe-near frames (AVAssetImageGenerator with tolerance, 256 px). Measures colour-histogram plus pixel change, adaptive scene cuts, a Vision attention-saliency box, and each frame's sharpness (Laplacian variance against a fixed reference) and mean luma.
   - `color`: per-clip medians of luma, 1st/99th percentile luma, mean chroma and grey-world channel means, from the same sampled frames. The pipeline computes `visual` and `color` in one pass; `color` alone skips saliency. `ColorAdjust.suggested(for:look:)` (Core, pure) turns the stats into a starting grade.
   - Outside the pipeline, `CoverFramePicker` ranks the `visual` samples (sharpness, a face from `faces`, exposure, saliency size; 2 s apart, away from the ends), then re-ranks the best with Vision face capture quality on full-resolution frames. `clipper cover` writes the winners as JPEG. For an edited timeline, `TimelineCover` scores the primary track's samples the same way at the timeline times that show them, adds a bonus where a caption page is on screen, and skips the first half second and transitions; `Exporter.renderFrame` renders the chosen frame through the export's composition (captions, titles, colour). `clipper cover <project>` and the app's Export sheet (**Save cover image…**) use both.
   - `keywords` (`KeywordTagger`): NaturalLanguage part-of-speech, name and lemma tags on the final transcript mark numbers, names, content nouns and shouted words, each with an emoji from `KeywordEmoji.table` when one fits.
   - Outside the pipeline, `TranscriptBriefer` asks the local LLM (`LocalLLM`, the same localhost-only client as the ranker) for a title, hook sentence, per-sentence importance, chapters, description and hashtags. Transcripts over 1500 words are split into parts and the answers combined. `clipper draft --llm` and the app's draft (when the local LLM is on in Settings) use its title when none is given.

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

## Manual editing and keyboard shortcuts

- **Edit commands** are pure `(Timeline) -> Timeline` functions in ClipperCore (`Commands.swift`, `Commands+Editing.swift`): insert/overwrite, connect (`PlaceItems`: a free track, else a new one, never disturbing anything), insert edit (`InsertEdit`: a gap on every unlocked track so everything stays in sync), lift/extract (`RemoveRange`), nudge, speed (`SetSpeed`), `Batch` (one undo step). Locked items are never cut into; cuts keep each caption word on one side and drop wordless caption pieces.
- **Keyboard**: `EditorAction` lists every action with factory shortcuts; `KeyBindings` stores only the user's changes in `settings.json` (`keyBindings`). In the app a local `NSEvent` monitor routes key presses in the main window to actions (stepping aside while typing in a text field, under a sheet, or in another window); only ⌘/⌃ shortcuts go on menus, because a plain-key menu equivalent would fire before a text field could type it. Settings ▸ Shortcuts records, removes and resets bindings.
- **Re-draft**: `Provenance.inputs` records the draft's clips and options; `Redraft.merge` lays the user's locked/added items and locked tracks over a fresh draft. One undo step.
- **Scripted smoke tests** (debug builds): `CLIPPER_LIBRARY` + `CLIPPER_DEBUG_SCRIPT` drive the editor with real key events against a scratch library (`App/Clipper/Models/DebugScript.swift`). See [editor.md](editor.md).
