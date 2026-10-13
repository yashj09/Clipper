# Code review — 13 October 2026

Full read of the codebase at commit `2ce81c7` (main): `Packages/ClipperKit` (all six modules and the CLI), `App/Clipper`,
`worker/`, `scripts/`, and the docs. No code was modified. Each finding was traced to its call sites before being listed.

## Verification status

- `swift build` in `Packages/ClipperKit`: clean, zero warnings.
- `swift test`: 103 tests in 26 suites pass (includes the live Apple Speech, Translation, whisper and local-LLM smoke tests).
- `xcodebuild -scheme Clipper`: BUILD SUCCEEDED with two warnings (`App/Clipper/Views/MainView.swift:244` deprecated
  localized interpolation; `App/Clipper/Views/InspectorView.swift:105` non-Sendable closure).

Overall the codebase is in good shape: clear module boundaries, deterministic drafting, careful DSP with correct
BS.1770 gating, robust worker protocol, and solid escaping in the ASS, iCalendar and XML writers. The problems cluster in
the newest layer (publishing) and in a few export and persistence edge cases.

Severity key: **CONFIRMED** = traced and definitely wrong; **POTENTIAL** = plausible, depends on inputs or runtime.

---

## High

### 1. `clipper publish now` can publish a different, future-scheduled post — CONFIRMED
- `Packages/ClipperKit/Sources/clipper/PublishCommand.swift:279` picks the `.scheduled` post with the largest `updated`.
- `Packages/ClipperKit/Sources/ClipperPublish/Queue/PublishQueue.swift:30` initialises `updated = scheduledAt`, so a
  post scheduled for next week has an `updated` in the future and wins over the one just created.
- **Failure:** schedule "A" for 2026-10-20, then run `clipper publish now "B"` → "A" is exported and uploaded now.
- **Fix:** have `Schedule.run` return the created post (or its id) and execute that; set `updated = Date()` in
  `ScheduledPost.init`; never derive audit fields from user-supplied dates.

### 2. No atomic claim in the publishing queue → duplicate uploads and permanently stuck posts — CONFIRMED
- `PublishQueue.due()` (`PublishQueue.swift:52`) returns `.scheduled`/`.partial` posts; the status only moves to
  `.exporting` after the caller has already started (`PublishCommand.swift:227`, `App/Clipper/Models/AppModel+Publishing.swift:79`).
- The `flock` only protects each read-modify-write of `queue.json`, not the workflow.
- **Failure A (double publish):** the app's "Run Due Posts" button (or "Publish Now") and the LaunchAgent's `run-due`
  both read the same due post before either marks it, and both export and upload it.
- **Failure B (stuck):** a crash or force-quit during export/upload leaves the post in `.exporting`/`.uploading`;
  `due()` never returns those states, so it is never retried and shows as in-progress forever.
- **Fix:** add `PublishQueue.claim(id) -> Bool` that transitions `scheduled → exporting` under the file lock and returns
  false if already claimed; callers skip unclaimed posts. On startup, requeue posts stuck in transient states older than
  a timeout (e.g. 2 h). Add a test with two queue instances racing on one file.

### 3. "Save as Template" crashes when the first media item on a track has no slot — CONFIRMED
- `Packages/ClipperKit/Sources/ClipperAutomation/TemplateBuilder.swift:35`:
  `Set(items.compactMap(\.slot)).count == 1 ? items[0].slot! : slug(track.name)` — the condition checks the *set* of
  non-nil slots, then force-unwraps the *first item's* slot.
- **Failure:** user inserts a manual clip (slot = nil) before the draft's auto clips on the primary track, then
  Save as Template (app sheet or `clipper templates save`) → trap.
- **Fix:** `items.compactMap(\.slot).first!` (or the set's only element).

---

## Medium

### 4. Export overwrites the previous output before the new one succeeds — CONFIRMED
- `Packages/ClipperKit/Sources/ClipperEngine/Export/Exporter.swift:99` removes the destination, then `AVAssetWriter`
  writes straight to it (`:125`).
- **Failure:** re-exporting over an existing file, then a failure or cancel → the last good export is gone.
- **Fix:** write to `<name>.partial.<ext>` (same directory) and rename on success; remove on failure.

### 5. Exporting with a preset of a different aspect re-crops media and mis-scales text — CONFIRMED
- `Exporter.swift:91` sizes the output from the preset; `Render/LayerGeometry.swift:17` normalises boxes against that
  size (so `.fill` re-crops every full-frame clip to the new aspect); `Render/ClipperCompositor.swift:46` derives
  `renderScale` from width only while text is rasterised at canvas size.
- **Failure:** vertical 1080×1920 timeline exported with `youtube-1080p` (the README's suggested re-export flow) →
  centre-cropped video and titles scaled by 1920/1080 ≈ 1.78×. The app's export sheet warns; the CLI does not.
- **Fix:** either letterbox/pillarbox (render at canvas aspect, pad to preset size) or refuse mismatched presets in
  the CLI; scale text by `min(outW/canvasW, outH/canvasH)`.

### 6. YouTube caption upload mislabels and duplicates sidecars — CONFIRMED
- `PublishCommand.swift:234` and `AppModel+Publishing.swift:90` collect every `.srt` whose name starts with the video
  stem (`clip.srt`, `clip.en.srt`, `clip.es.srt`, and also `clip2.srt`).
- `Packages/ClipperKit/Sources/ClipperPublish/YouTube/YouTubePublisher.swift:170` labels the untagged file "en".
- `Packages/ClipperKit/Sources/ClipperCore/Subtitles.swift:55` skips the tagged copy when there is a single language,
  so Spanish-only captions are uploaded as English; with a hidden translation present, `clip.srt` and `clip.en.srt`
  are both uploaded (duplicate "en").
- **Fix:** when tagged sidecars exist skip the untagged one; otherwise label the untagged file with the visible caption
  track's `language`. Match the stem exactly (`stem + "." + lang + ".srt"`), not by prefix.

### 7. Instagram silently upgrades a requested private post to public — CONFIRMED
- `PublishCommand.swift:239` and `AppModel+Publishing.swift:95` override `visibility` to `.public` for Instagram,
  bypassing the guard in `ClipperPublish/Instagram/InstagramReels.swift:34`.
- **Failure:** user picks "Private", ticks Instagram → the Reel is public.
- **Fix:** reject the combination with the existing validation error (or require an explicit confirmation).

### 8. Pending autosave is lost on project switch or quit — CONFIRMED
- `App/Clipper/Models/EditorModel.swift:99-108` debounces saves by 1 s in a `Task { [weak self] … }`.
- `App/Clipper/Models/AppModel.swift:110-119` replaces `editor` on open; the old task's `self` becomes nil and the
  snapshot is never written. Quitting within the debounce window has the same effect.
- **Fix:** flush the pending save synchronously in `AppModel.open`, `delete` and on `applicationShouldTerminate`
  (e.g. an `EditorModel.flushSave()`).

### 9. `publish install-agent` embeds an unreliable binary path and ignores launchctl failures — CONFIRMED
- `PublishCommand.swift:321` resolves `CommandLine.arguments[0]` against the cwd; running `clipper` from `PATH` stores a
  non-existent path and the agent silently never runs.
- `:311-313`, `:333-335`: `launchctl` exit status is ignored; "Installed" is printed regardless.
- POTENTIAL: the ad-hoc-signed CLI changes code identity on every rebuild, so Keychain reads from the agent trigger
  "allow access" prompts.
- **Fix:** use `Bundle.main.executableURL` / `_NSGetExecutablePath`; check `terminationStatus`; document the signing
  caveat (or sign the CLI with a stable identity).

### 10. The "Write SRT/VTT caption files" setting does nothing — CONFIRMED
- `ClipperCore/Settings.swift:63` and `App/Clipper/Views/Sheets.swift:245` expose `export.writeSidecars`;
  `Exporter.swift:178` always writes the preset's sidecars.
- **Fix:** pass the setting into `Exporter.export` (or remove the toggle).

### 11. FFmpeg transcode can deadlock and block every export — POTENTIAL
- `ClipperEngine/Media/Transcoder.swift:48-57` reads stderr only in the termination handler. A decode that logs more
  than the pipe buffer (≈64 KB, e.g. per-frame errors on a corrupt file) blocks ffmpeg forever while holding the
  `EncodeScheduler` slot, so all exports wait. No cancellation handler terminates the process.
- **Fix:** drain stderr with a `readabilityHandler`; add `withTaskCancellationHandler` that terminates the process.

### 12. A stray request aborts OAuth sign-in — CONFIRMED
- `ClipperPublish/OAuth/OAuthClient.swift:101` yields `.stateMismatch` for any hit on the callback path, so a single
  unrelated request ends the flow (contrary to the comment at `:205`).
- **Fix:** answer 400 but keep listening; only a matching `state` resolves the continuation.

---

## Low

13. **Limiter tail never flushed.** `Exporter.swift:164` shifts audio back by the look-ahead latency but nothing calls
    `TruePeakLimiter.flush()` (`ClipperEngine/Audio/Limiter.swift:153`); every normalised export loses the last ≈5 ms.
14. **CLI crash on bad `--llm`.** `clipper/HighlightsCommand.swift:52` force-unwraps `URL(string: llm)`.
15. **Remote catalog filename trusted.** `clipper/MusicCommand.swift:77` and `AppModel.swift:278` build the download path
    from the Incompetech catalog's `filename` unsanitised; `ClipperAutomation/MusicCatalog.swift:45` force-unwraps the URL.
16. **LLM ranker follows redirects.** `ClipperAnalysis/Highlights/LocalLLMRanker.swift:236` uses `URLSession.shared`; a
    307 from the local server would resend transcripts to a remote host. Add a no-redirect delegate like `HTTPClient`.
17. **Unpinned model weights.** `worker/clipper_worker/music.py:111` downloads from the HF repo's `main` with no revision,
    unlike the pinned ACE-Step code commit in `pyproject.toml`.
18. **POST retried after connection loss.** `ClipperPublish/HTTP/HTTPClient.swift:99-101`: token exchange may replay a
    one-time code (invalid_grant) and TikTok init may create orphan drafts that count toward the 5-pending limit.
19. **NSUndoManager bridge inconsistent.** `EditorModel.swift:90-97` registers an entry per `perform` (including every
    coalesced slider tick) but the Edit menu bypasses it (`ClipperApp.swift:19-24`); the two stacks drift. Remove or
    route the menu through it.
20. **Periodic time observer never removed.** `EditorModel.swift:203`; add `deinit { player.removeTimeObserver(…) }`.
21. **Timeline canvas.** `App/Clipper/Views/Timeline/TimelineCanvas.swift:343,351,352` force-unwrap row lookups during
    drags; `thumbs` (`:59`) is unbounded; the Delete key (`:412`) ignores the ripple default the toolbar button honours;
    every thumbnail completion triggers a full `layoutTimeline()` (`:210`).
22. **Dead subsystems.** `ClipperLibrary/Library+Jobs.swift` has no consumers; `EncodeScheduler.shouldYield` is never
    read, so background encodes never yield despite ARCHITECTURE.md §Rendering 9; `Library.proxiesURL(for:)` is unused.
23. **Double composition build per normalised export.** `Exporter.swift:72` (measure) and `:102` (render) decode all
    audio twice.
24. **GPU caches.** `ClipperEngine/Render/GPU.swift:92` image cache is unbounded; no `CVMetalTextureCacheFlush`; the
    `CVMetalTexture` wrappers from `:56` are not retained until the command buffer completes (POTENTIAL).
25. **`maxLines` unused.** `ClipperEngine/Text/TextRenderer.swift:39` documents a cap that is never applied.
26. **Caption page dropped.** `ClipperAutomation/Passes/Captions.swift:39` shrinks the previous page to zero length when
    two pages start on the same frame; `:52` then silently drops it (words lost).
27. **Build path embedded.** `ClipperAnalysis/Worker/PythonWorker.swift:175` uses `#filePath`, leaking the build
    machine's source path into release binaries.
28. **Docs drift.** `README.md:13` says phases 0–3 are built; `docs/ROADMAP.md` marks phase 4 complete.
29. **Misc.** `clipper/Services.swift:139` `Console.statusShown` is `nonisolated(unsafe)` and mutated from progress
    callbacks on arbitrary threads; `Sheets.swift:278` saves settings and restarts the folder watcher on every
    keystroke; `KeychainCredentialStore.swift:44` sets `kSecAttrAccessible`, which the file-based login keychain ignores.

---

## Architecture and maintainability

- The layering holds: `ClipperCore` is pure, passes are seeded and byte-reproducible, and the app shares
  `DraftPipeline` with the CLI as ARCHITECTURE.md promises.
- **Duplicated wiring** that should live in the package: post execution exists twice (`PublishCommand.execute`,
  `AppModel.execute`); caption sidecar discovery is copied in both; `Services.kinds(for:)` is re-implemented inline at
  `AppModel.swift:142-145`. A `PublishRunner` in `ClipperPublish` would fix findings 2, 6 and 7 in one place.
- `AppModel` (373 lines + 139-line extension) is approaching god-object territory.
- Scaffolding that is built but unused (jobs table, `shouldYield`, proxies folder) should be labelled as such or removed.

## Biggest test gaps

- The App target has no tests at all: `EditorModel` save/undo behaviour and `PlayerController` rebuild races are untested.
- `ClipperPublishTests/QueueTests.swift` covers ordering and iCalendar output, not concurrent claiming, stuck-state
  recovery, or the `publish now` selection bug (findings 1, 2).
- No exporter test covers a preset whose aspect differs from the canvas, limiter tail flushing, or overwrite-on-failure
  (findings 4, 5, 13).
- `TemplateBuilder` tests use draft-generated timelines only; a timeline with mixed user/auto items on one track would
  have caught finding 3.
- Sidecar → YouTube language mapping (finding 6) and `KeychainCredentialStore` are untested; only the in-memory store is
  exercised.

## Suggested order of work

1. Findings 1–3 (publishing correctness, template crash): small, isolated fixes with tests.
2. Findings 4, 8 (data loss on export and autosave).
3. Findings 5–7, 10 (export aspect, caption labelling, Instagram visibility, dead setting).
4. Consolidate publish execution into `ClipperPublish` and add queue concurrency tests.
5. Sweep the Low list.

---

## Verification after fixes (13 October 2026, working tree on top of `2ce81c7`)

- `swift build`: clean, zero warnings. `swift test`: 348 tests in 78 suites pass (97 + 22 + 47 + 51 + 28 + 103 per target),
  including 12 new suites (`PublishRunnerTests`, `CanvasFrameTests`, `TextMaxLinesTests`, `LimiterTailTests`,
  `ExportOverwriteTests`, `ProcessRunnerTests`, `SidecarLanguageTests`, `HTTPRetryTests`, `CaptionPagingTests`,
  `MusicCatalogSafetyTests`, `TemplateBuilderMixedSlotTests`, `ExportPresetSettingsTests`).
- `xcodebuild -scheme Clipper`: BUILD SUCCEEDED; the same two pre-existing warnings (`MainView.swift:244`, `InspectorView.swift:105`).
- The pinned Hugging Face revision in `worker/clipper_worker/music.py` resolves (HTTP 200).

| # | Finding | Status |
|---|---|---|
| 1 | `publish now` picks wrong post | Fixed: `Now` runs the post it created; `updated` is set from the clock. Tested. |
| 2 | No queue claim / stuck posts | Fixed: `PublishQueue.claim` under the file lock, `runnerPID`, `recoverInterrupted`; shared `PublishRunner` used by CLI and app. Tested incl. two runners racing. |
| 3 | TemplateBuilder force-unwrap | Fixed (`slotIDs.first!`). Tested. |
| 4 | Export overwrites previous file | Fixed: `.partial.<ext>` + `replaceItemAt`. Tested. |
| 5 | Aspect mismatch re-crops / mis-scales text | Fixed: `CanvasFrame` letterboxes, uniform text scale, scissor for bars. Tested. |
| 6 | YouTube caption labelling / duplicates | Fixed: `Subtitles.distinctSidecars`, `PublishRequest.Caption.language`, exact-name matching. Tested. |
| 7 | Instagram silently public | Fixed: `ScheduledPost.problems` rejects at schedule time (CLI + sheet); runner passes visibility through. Tested. |
| 8 | Autosave lost on switch/quit | Fixed: `flushSave` on open/delete and `applicationWillTerminate`. |
| 9 | `install-agent` path / ignored errors | Fixed: `Bundle.main.executableURL`, launchctl status checked, Keychain caveat printed. |
| 10 | `writeSidecars` setting ignored | Fixed: `ExportPreset.applying(_:)`; publishing exports force sidecars on. Tested. |
| 11 | FFmpeg stderr deadlock / no cancel | Fixed: drained `LogTail`, cancellation terminates. Tested. |
| 12 | Stray callback aborts OAuth | Fixed: only a matching state settles the flow. Tested. |
| 13 | Limiter tail dropped | Fixed: `AudioStage.flush`, `StageBox.tail`, appended by the pump. Tested. |
| 14–22, 24–29 | Low items | Fixed (14, 15, 16, 17, 18, 19, 20, 21, 22, 24, 25, 26, 27, 28, 29). |
| 23 | Composition built twice per normalised export | Not addressed (performance only). |

No regressions found in the changed code. Notes for later, none blocking:
- `TextRenderer` now shrinks text (down to 50 %) to honour `maxLines`; the ASS sidecar still uses the style's nominal size,
  so a very long title can differ slightly between burn-in and `.ass`.
- `AppModel.execute` reports "already being published or no longer pending" for a cancelled post too; the wording could
  distinguish the two.
