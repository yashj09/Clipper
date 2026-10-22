# Code review: automatic-editing run (`5c77894..dd88431`)

Date: 2026-10-22
Scope: 38 commits, 79 files, +5539/−544
Mode: read-only investigation. No repository code was modified.

## Verdict

The automatic-editing run is in good shape at the level of "does it build, do the tests pass, does the end-to-end script pass". The package builds, all 534 tests pass (4 opt-in tests skipped), the macOS app builds with no errors, and `scripts/e2e.sh` passes for both talking-head and vlog. Determinism holds: a draft with every feature on produced byte-identical JSON in two separate processes. No High-severity crash or data-loss bug was found in the core passes.

The real problems are one advertised feature that cannot work, several places where an LLM reply or a new pass interacts badly with an older subsystem, and a sharpness measure that will cut sharp footage.

Every finding below was verified by running code or by tracing a definite code path unless marked UNCERTAIN.

## Verification summary

| Check | Result |
|---|---|
| `swift build` (ClipperKit) | OK |
| `swift test` (all 6 test targets) | 534 passed, 4 skipped (opt-in), 0 failed |
| `xcodegen` + `xcodebuild -scheme Clipper -configuration Debug` | BUILD SUCCEEDED, 0 errors, 1 new warning |
| `scripts/e2e.sh` | all 5 checks PASS |
| FCPXML marker output vs Apple's 1.11 DTD (`xmllint --dtdvalid`) | valid (3 `<marker>` elements) |
| Live brief against Ollama `qwen3.5:9b` | parsed in 44 s |

Details:

- e2e: pauses removed 36.6 s → 30.2 s, −14.0 LUFS, SRT written, vlog "Sped up 3 pauses", vlog export matches timeline. Talking-head notes: "Removed 6.4s…", "Added 5 zooms (5 on emphasis…)", "Added 2 callouts", "Added 7 sound effects", "Colour-matched 1 clip".
- New compiler warning in this range: `Packages/ClipperKit/Sources/ClipperAnalysis/Pipeline/AnalysisPipeline.swift:90:75` capture of non-Sendable type `T.Type` in an isolated closure (KindSpec generic init).
- The repo test `fcpxmlIsWellFormedPerXmllint` only DTD-validates when `CLIPPER_FCPXML_DTD_DIR` is set. No DTDs are installed on this machine. Validation here used CommandPost copies of the Apple DTDs.

## Features in range

Speech edits (retakes, false starts), emphasis zooms (ZoomCurve), sped-up pauses (SpeedUpRule), BeatSnap, local-LLM TranscriptBriefer (LocalLLM actor, Ollama / LM Studio / mlx), KeywordTagger (NLTagger), callouts and emoji captions, hook cold open, B-roll cutaways, ColorStats and ColorAdjust.suggested, CoverFramePicker and TimelineCover, synthesised SFX, bad shots, profanity mute and bleep, PublishDefaults (YouTube chapters and hashtags), FCPXML and OTIO markers, `DraftPipeline.analysisKinds`.

## Findings, most severe first

### High

#### 1. `--broll-tag` and "tagged b-roll" can never match anything

Status: VERIFIED.

Nothing in the CLI, app or import path writes a user tag on media. The only tags ever set are the internal `music` and `sfx`, and `updateAsset` is called only by proxy code. The README example `--broll-tag b-roll` therefore always prints "No library video is tagged b-roll". The app's hint "named or tagged b-roll" is half wrong.

Evidence: grep of every write to `MediaAsset.tags`; importing `desk b-roll.mov` into a scratch library and running the draft with `--broll-tag b-roll`.

Files:
- `Packages/ClipperKit/Sources/clipper/Commands.swift:63`
- `Packages/ClipperKit/Sources/ClipperAutomation/Passes/BRoll.swift:104`
- `App/Clipper/Views/Sheets.swift:213`

Fix: add a `clipper tag` command and an app affordance, or make the CLI flag fall back to name matching like `isBRoll`. Until then correct the README and the hint.

### Medium

#### 2. Missing importance scores become real zeros

Status: VERIFIED.

`importances()` pads a short or absent array with 0 and `SpeechPlan` only checks the count, so a reply without an `importance` key (or a miscounted one) makes the unscored sentences score 0. The hook is then rejected (0 < 0.6 minImportance) and duration trimming (`Cutting.fit`) drops exactly those sentences first, biased toward the end of the video. The existing test `oneRequestCleansAndClampsTheAnswer` expects `[1.5, -0.2, 0.5]` → `[1, 0, 0.5, 0]` for four sentences, which locks this behaviour in.

Files:
- `Packages/ClipperKit/Sources/ClipperAnalysis/LLM/TranscriptBriefer.swift:163`
- `Packages/ClipperKit/Sources/ClipperAutomation/Passes/Speech.swift:91`
- `Packages/ClipperKit/Sources/ClipperAutomation/Passes/Cutting.swift:187`

Fix: leave `sentenceImportance` empty when the array is missing or clearly short; pad only small miscounts.

#### 3. A chapter that starts on the hook sentence wipes out the YouTube chapter list

Status: VERIFIED (probe).

Chapter markers are placed on the item with the earliest source start that ends after the chapter time. After a cold open that item is the hook at timeline 0, so the chapter lands at 0.07 s and "Intro" moves to the hook cut at 3.4 s. The first chapter is then under 10 s, which makes `PublishDefaults.chapterLines` drop every chapter.

Evidence: with hook, markers were `["0.07 Chapter: Pricing", "3.37 Chapter: Intro"]`; without hook, `["0.07 Intro", "7.07 Pricing"]`.

Files:
- `Packages/ClipperKit/Sources/ClipperAutomation/Passes/Speech.swift:298`
- `Packages/ClipperKit/Sources/ClipperAutomation/DraftPipeline.swift:178`

Fix: skip the hook items when placing chapters; put a chapter that starts inside the hook at its next body item.

#### 4. BeatSnap pushes the draft past `maxDuration`

Status: VERIFIED (probe).

The fit trims to the cap, then BeatSnap may move the final end forward by up to the 0.15 s tolerance with nothing capping it (beats are requested until `total + tolerance`). The "Trimmed to" note reports the pre-snap length. A sweep of 400 caps on the test input produced 22 drafts over the cap by more than a frame (up to 0.133 s).

Files:
- `Packages/ClipperKit/Sources/ClipperAutomation/DraftPipeline.swift:105`
- `Packages/ClipperKit/Sources/ClipperAutomation/Passes/Cutting.swift:218`

Fix: pass the cap into `beatSnap` and refuse a last-segment snap that exceeds it.

#### 5. Save-as-template from a talking-head draft loses caption emoji and the B-roll slot

Status: VERIFIED.

`TemplateBuilder` rebuilds the caption rule from its style alone (`rules.captions = CaptionRule(style: style)`), resetting `emoji`, and keeps only slots whose tracks have items. A draft with no cutaways drops the `broll` slot while keeping `rules.broll`, so later drafts from that template never cut away. `TemplateBuilderTests.talkingHeadRoundTrips` asserts `slots.count == 1`, encoding the loss.

Files:
- `Packages/ClipperKit/Sources/ClipperAutomation/TemplateBuilder.swift:106`
- `Packages/ClipperKit/Tests/ClipperAutomationTests/TemplateBuilderTests.swift:24`

Fix: keep the based-on caption rule and change only the style; carry the B-roll slot whenever the rule is set; update the test.

#### 6. Redraft throws away user markers

Status: VERIFIED.

`Redraft.merge` never reads `old.markers`, so a re-draft replaces every marker, including ones the user added in the editor. This gap predates the range but now matters because drafts write Retake, Hook and Chapter markers and the chapter markers feed publishing.

File: `Packages/ClipperKit/Sources/ClipperAutomation/Redraft.swift:45`

Fix: give markers an origin (or treat non-prefixed names as the user's) and carry them over.

#### 7. A bleep covers only the first 0.25 s of a muted stretch

Status: VERIFIED (export measurement).

The synthesised bleep file is 0.25 s and `effectItem` stops at the file end, so a long or merged profane stretch gets a short beep then silence.

Evidence: bleep window −11.7 dB RMS; the rest of the word (2.3–2.6 s) −77.6 dB.

Files:
- `Packages/ClipperKit/Sources/ClipperAutomation/Passes/Profanity.swift:46`
- `Packages/ClipperKit/Sources/ClipperEngine/Audio/SoundEffects.swift:100`

Fix: synthesise a longer bleep ramped only at the start and let `effectItem` cut it at the stretch end.

#### 8. Sharpness measures texture, not focus, so flat but sharp shots get cut as blurry

Status: VERIFIED.

The score is Laplacian variance over the whole frame (`/(v+500)`). Slides, screen recordings, sky and plain walls read low; noisy frames read sharp. The repo's own `rotated_marker.mov` fixture (flat grey plus a red square) measures 0.016, far under the 0.15 `BadShotRule.minSharpness` threshold, so a silent stretch of it would be cut in vlog or montage. The new test assertion only checks the value lies in 0…1.

Files:
- `Packages/ClipperKit/Sources/ClipperAnalysis/Vision/VisualActivityAnalyzer.swift:269`
- `Packages/ClipperKit/Sources/ClipperAutomation/Passes/BadShots.swift:15`

Fix: normalise for content (edge-relative or clip-median-relative) and add the marker fixture as a "sharp" case.

#### 9. The project cover is scored on the primary track but rendered as the full composite

Status: VERIFIED (probe picked a time inside an overlay).

`TimelineCover.pick` reads only the first `.video` track and ignores overlays and `hidden`, so with B-roll (a full-frame overlay) the chosen time can render an unscored B-roll frame. Faces cropped out by the 9:16 reframe still earn the face bonus.

File: `Packages/ClipperKit/Sources/ClipperAnalysis/Vision/TimelineCover.swift:19`

Fix: skip times covered by a visible higher track and count faces only inside the crop.

#### 10. The "Re-rank highlights with a local model" setting now silently changes every draft

Status: VERIFIED.

`useLLM` also triggers a brief on each draft (title burned in, hook moved, trimming by model scores, chapter markers), including watch-folder drafts, while the Settings section is still labelled "Local LLM (optional, for ranking highlights)". Brief failures are swallowed by `try?`.

Files:
- `App/Clipper/Models/AppModel.swift:220`
- `App/Clipper/Views/Sheets.swift:243`

Fix: a separate "use the local model for drafts" toggle, or at least an honest label, and surface failures.

#### 11. Every clip is briefed, including B-roll candidates and facecams, with no cancel

Status: VERIFIED (code path).

Only main-slot briefs are ever used, yet both app and CLI transcribe and brief every clip. With `autoBRoll` on that is every library video named b-roll, each up to 120 s per chunk inside `makeDraft`. This contradicts ARCHITECTURE.md row 14.

Files:
- `App/Clipper/Models/AppModel.swift:222`
- `Packages/ClipperKit/Sources/clipper/Commands.swift:81`

Fix: brief main-slot clips only.

#### 12. In the app, one bad auto-added B-roll file aborts the whole draft

Status: VERIFIED (code path, not run).

Auto candidates are not checked for existence and are analysed inside the same `do/catch` as the main clips, so a moved file fails "Create draft" with "Analysis failed" for a recording the user never linked to it.

File: `App/Clipper/Models/AppModel.swift:191`

Fix: skip missing candidates and analyse them in their own `do/catch`.

#### 13. HDR luma and colour are measured without tone mapping

Status: UNCERTAIN as to the correct target; numbers verified.

Frames are measured in an 8-bit sRGB context. Identical 10-bit code values at 75 % read 0.772 (BT.709), 0.600 (HLG) and 0.999 (PQ). HLG reference white reads as mid-grey, so colour matching pushes exposure up; bright PQ (75–90 %) clips to 1.0, which bad-shot reads as blown out (> 0.95). No test asserts anything on the HDR fixtures.

File: `Packages/ClipperKit/Sources/ClipperAnalysis/Vision/VisualActivityAnalyzer.swift:239`

Fix: measure frames the way the renderer shows them.

### Low

#### 14. `LLMResponseParser.int` traps on huge finite doubles

Status: VERIFIED.

`return d.isFinite && d == d.rounded() ? Int(d) : nil` traps for e.g. 1e20. The briefer newly routes `hook` and chapter ids through it.

File: `Packages/ClipperKit/Sources/ClipperAnalysis/LLM/LLMResponseParser.swift:84`

Fix: use `Int(exactly:)`.

#### 15. `Transcript.sentences` splits at abbreviations

Status: VERIFIED (live run).

Splits at "Dr.", "e.g.", "U.S." and "Wait...". In the live Ollama run "Dr." became its own sentence scored 0.0. Note that `Transcript.sentences` (Core) and `Speech.sentences` (Automation) are two different splitters; the brief uses the Core one.

File: `Packages/ClipperKit/Sources/ClipperCore/Analysis.swift:39`

#### 16. Sound-effect assets appear as user media

Status: VERIFIED.

SFX files are imported as library assets but every media filter excludes only `music`, so Whoosh / Pop / Ding / Bleep appear in the Media browser, in `clipper info` counts (Media: 4), and get analysed by a bare `clipper analyze`.

Files:
- `Packages/ClipperKit/Sources/clipper/Commands.swift:145`
- `Packages/ClipperKit/Sources/clipper/Commands.swift:275`
- `App/Clipper/Models/AppModel.swift:95`

Fix: filter `sfx` alongside `music`.

#### 17. `"beatSnap": {}` and `"speedUp": {}` fail to decode

Status: VERIFIED.

Those two rules keep synthesized Codable; every other new rule defaults missing keys.

File: `Packages/ClipperKit/Sources/ClipperCore/Template.swift`

#### 18. Cold open with sped-up pauses leaves fast silence on both sides of the jump cut

Status: VERIFIED (probe). No built-in template combines both, but rules are user JSON.

File: `Packages/ClipperKit/Sources/ClipperAutomation/Passes/Hook.swift:30`

#### 19. Profanity unmasked in hook marker and note

Status: VERIFIED for the hook marker and "Cold open" note. UNCERTAIN (read only) whether B-roll matching skips profane words.

Files:
- `Packages/ClipperKit/Sources/ClipperAutomation/Passes/Hook.swift:29`
- `Packages/ClipperKit/Sources/ClipperAutomation/Passes/BRoll.swift:64`

#### 20. Any silent primary segment disables importance trimming for the whole draft

Status: VERIFIED. Vlogs with B-roll footage in the primary never trim by the brief (`Cutting.scored`).

File: `Packages/ClipperKit/Sources/ClipperAutomation/Passes/Cutting.swift:172`

#### 21. Unknown callout style produces no callouts and no warning

Status: VERIFIED. The pop sound still fires and captions still lose their emoji.

File: `Packages/ClipperKit/Sources/ClipperAutomation/DraftPipeline.swift:287`

#### 22. One short chapter gap drops the entire YouTube chapter list

Status: VERIFIED. One pair under 10 s drops the whole list rather than the offending chapter. The YouTube-only chapter block also goes into the Instagram caption.

File: `Packages/ClipperKit/Sources/ClipperPublish/PublishDefaults.swift:32`

#### 23. `publish now --description` and dry-run output

Status: VERIFIED. `publish now` re-parses options as `["--description", value]`, so a value starting with "-" fails (pre-existing, but this line was edited in range). The dry run prints generic text rather than each platform's actual title and caption, and prints the description twice.

File: `Packages/ClipperKit/Sources/clipper/PublishCommand.swift:284`

#### 24. Keyword "emphasis" is text-only

Status: VERIFIED. "AI", "OK", "USA", "Thanks!" are tagged emphasis and never called out; "dollars!" loses its noun tag; lowercase names come back as nouns.

File: `Packages/ClipperKit/Sources/ClipperAnalysis/Keywords/KeywordTagger.swift:72`

#### 25. SFX files unversioned; concurrent `ensure` can fail

Status: VERIFIED (code path). SFX files and asset keys carry no version, so a future length change desynchronises old libraries. Two processes writing a missing file at once make the slower `moveItem` fail.

File: `Packages/ClipperKit/Sources/ClipperEngine/Audio/SoundEffects.swift:16`

#### 26. Analysis kind mismatches

Status: VERIFIED. Talking-head requests only `.faces`, so the saliency fallback in `reframed` never has data when no face is found. The app adds keywords whenever it transcribes but the CLI does not. `--model` without `--llm` is silently ignored.

Files:
- `Packages/ClipperKit/Sources/ClipperAutomation/DraftPipeline.swift:438`
- `Packages/ClipperKit/Sources/clipper/HighlightsCommand.swift` (`LLMOptions`)

#### 27. `Speech.timedWords` ignores clip speed

Status: UNCERTAIN impact. Safe today because sped-up pieces carry no words; a trap for any future sped-up speech.

File: `Packages/ClipperKit/Sources/ClipperAutomation/Passes/Speech.swift:321`

#### 28. Smaller items

- Brief cache id maps `a:b`, `a/b`, `a_b` to one id (`analyzerID` replaces `:` `/` `\` with `_`) and the digest omits sentence start times.
- A nested object containing `chapters` is accepted as the reply.
- The multi-chunk hook is not limited to the offered candidates.
- Keywords cache can outlive its transcript (UNCERTAIN).
- BeatSnap's no-speech check only sees transcript words, so it can extend a cut 0.15 s into a removed breath or blurry stretch.
- New Sendable warning at `Packages/ClipperKit/Sources/ClipperAnalysis/Pipeline/AnalysisPipeline.swift:90`.

#### 29. Test gaps

- `RenderFrameTests` returns early (and passes) when fixtures are absent.
- DTD validation runs only with `CLIPPER_FCPXML_DTD_DIR`.
- The opt-in OpenTimelineIO read test exports a timeline without markers, so OTIO markers are never read by real OpenTimelineIO.
- Nothing covers: chapters with a cold open, a cap with BeatSnap on, bleep coverage of long stretches, missing `importance`, a cover under an overlay, B-roll versus hook end-to-end.

## Checked and found sound

- AnalysisPipeline refactor preserved every cache id, version, applicability and dependency. Only `visual` bumped to version 2, so old samples without sharpness are a cache miss rather than silent zeros, and old JSON still decodes. Keywords id is tied to the transcript id.
- LocalLLMRanker move onto `LocalLLM` keeps every behaviour (endpoint presets, local-only refusal, redirect block, format fallback, retry, batching).
- Sentence numbering is consistent between the briefer and every consumer.
- Hook, retake, false-start, sped-up-pause, bad-shot and profanity-mute logic handled every edge input tried (empty transcript, single word, 1 s clip, no sentence terminators, keyword on the last word under a 5 s cap) without crashes or validation errors.
- Determinism: byte-identical draft JSON across two processes with every feature on.
- The 60 dB mute survives loudness normalisation (−76.5 dB vs −16.5 dB around it). SFX are mixed equally in both channels and counted by normalisation. Preview and export build audio identically.
- FCPXML markers validate against the 1.11 DTD and land in local time on the right spine element, including a 2× clip. OTIO markers have the right schema and timing.
- Publish defaults, the 5000-byte YouTube trim, Instagram limits, YouTube metadata (unchanged except description), and persistence of the `autoBRoll` setting all behave as described. Publish dry run has no side effects.
- No new off-main-actor state in the app. The Resampler one-liner is correct.

## Method

- Range established as `5c77894..HEAD` (HEAD `dd88431`), full diff read split by area (core, automation, analysis, integration).
- Verification run on this machine: `swift build`, `swift test`, `xcodegen` + `xcodebuild`, `scripts/e2e.sh`, `xmllint --dtdvalid` against Apple FCPXML 1.10/1.11 DTDs.
- Three read-only review lanes (automation, analysis/LLM, integration) ran probes in throwaway worktrees; all lane findings above were independently re-checked against the code before inclusion.
- Scratch artifacts (logs, per-area diffs, probe sources, DTD-validated FCPXML output) were kept under `/tmp/clipper-review/` and are not part of the repository.

## Resolution (2026-10-22)

Fixed in the working tree after this review. Verification after the fixes: `swift build` clean, `swift test` 550 passed (104 + 22 + 73 + 95 + 119 + 137) with the same 4 opt-in tests skipped, the app builds with no errors and the KindSpec Sendable warning gone, `scripts/e2e.sh` all 5 checks PASS, and a CLI smoke of `clipper tag`, `draft --broll-tag`, `info` and `publish now --dry-run --description "-…"`.

| # | Status | Fix |
|---|---|---|
| 1 | Fixed | New `clipper tag <asset>… <tag> [--remove]` writes user tags; README and app hint corrected |
| 2 | Fixed | `importances` returns none for a missing or short list; a shortfall of at most 1 in 10 gets the median; chunked briefs with any unscored chunk score nothing |
| 3 | Fixed | Chapter markers are placed on the body after the cold open; a chapter starting inside the hook marks where its body goes on |
| 4 | Fixed | `beatSnap` takes `maxDuration` and refuses a last-segment snap past it |
| 5 | Fixed | Template builder keeps the based-on caption rule (emoji) and carries the B-roll slot whenever `rules.broll` is set |
| 6 | Fixed | `Marker.origin` (decodes as `.user` when absent); drafts mark theirs `.auto`; `Redraft.merge` keeps the user's |
| 7 | Fixed | Bleep effect is 2 s and cut to the silenced stretch |
| 8 | Fixed | Sharpness is the Laplacian energy a 3×3 blur removes, gated by absolute edge energy; verified on `rotated_marker.mov` (0.75 sharp, 0.03 after a 6 px Gaussian blur) |
| 9 | Fixed | `TimelineCover` skips moments covered by a visible full-frame item on a higher track (face-in-crop not changed) |
| 10 | Fixed | Settings label names both uses; brief failures surface as draft warnings |
| 11 | Fixed | App and CLI brief and LLM-transcribe main-slot clips only |
| 12 | Fixed | Missing auto B-roll files are skipped; one that fails analysis is dropped with a warning |
| 13 | Fixed | `AVAssetImageGenerator.dynamicRangePolicy = .forceSDR` so HDR frames are measured as rendered |
| 14 | Fixed | `Int(exactly:)` |
| 15 | Fixed | `Transcript.endsSentence` shared by both splitters: titles, initials and a lowercase next word do not end a sentence |
| 16 | Fixed | `MediaAsset.isUserMedia` used by the app, `analyze` and `info` |
| 17 | Fixed | Defaulting decoders for `BeatSnapRule` and `SpeedUpRule` |
| 18 | Fixed | The cold open drops a sped-up pause on either side of the hook |
| 19 | Fixed | Profanity masked in the hook note and marker; B-roll matching skips profane words |
| 20 | Fixed | Silent segments no longer switch importance trimming off |
| 21 | Fixed | Unknown callout style warns and places no callouts, so no pops and no emoji removal |
| 22 | Fixed | A chapter under 10 s folds into the one before it instead of dropping the list. Instagram caption still carries the chapter block (one description for all platforms; not changed) |
| 23 | Fixed | `publish now` re-parses options as `--name=value`; dry run no longer prints the description twice. A dash-leading value must be given as `--description="-…"` on the outer command too (ArgumentParser). Output is still not per platform |
| 24 | Fixed | Names and nouns take precedence over a bare "!"; "thanks" is a stop noun |
| 25 | Fixed | SFX files and keys carry `SoundEffects.version`; a concurrent writer of the same file is not an error |
| 26 | Fixed | Face framing requests `.visual` too; the app no longer adds keywords on its own; `--model` without `--llm` is rejected |
| 27 | Fixed | `timedWords` honours clip speed |
| 28 | Fixed | Brief cache id digests the model and sentence start times; multi-chunk hook limited to candidates; `beatSnap` never enters excluded source; Sendable warning gone. Not changed: keywords cache lifetime (uncertain), nested-object reply (not a defect) |
| 29 | Partly | Tests added for 2, 3, 4, 6, 7, 8, 9, 15, 17, 18, 19, 20, 21, 22, 24, 25, 27 and the render test now reports itself skipped without fixtures. DTD validation and the OpenTimelineIO read remain opt-in |
