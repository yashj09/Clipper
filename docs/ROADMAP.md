# Roadmap

Each phase has an exit test. We don't start the next phase until the current one passes.

## Phase 0: documents and de-risking spikes ✅ (see [phase0-results.md](phase0-results.md))
- [x] Research the open-source landscape ([research.md](research.md))
- [x] Architecture and ADRs ([ARCHITECTURE.md](ARCHITECTURE.md), [adr/](adr/))
- [x] S1 Preview/export parity. Same Metal compositor in AVPlayer and in export. PSNR must exceed 45 dB. Scene: 2 video layers, text, keyframed transform, 1080×1920 at 60 fps.
- [x] S2 HDR → SDR tone mapping (HLG/PQ 10-bit → Rec.709). Result: we tone-map ourselves (ADR 0006). Real iPhone clip check pending.
- [x] S3 Speech-to-text: SpeechTranscriber vs whisper.cpp. Compare word error rate (WER), word-boundary error (target under 60 ms), and filler retention.
- [x] S4 Timeline view: AppKit/CALayer, 8 tracks, 2,000 items, 60 fps while scrolling and zooming.
- [x] S5 Long media: seeking to a frame takes 28 ms on the original and 4 ms on the proxy. Proxy generation runs at 6.5×, limited by decoding, so proxies are optional.
- [x] Write up results ([phase0-results.md](phase0-results.md))

## Phase 1: clips → templated short ✅ (built; real-use exit pending)

Library and import, analyzers, compositor, four built-in templates, three caption styles. Also: pro timeline, inspector, music browser, export presets with SRT/VTT, settings, and the `clipper draft` CLI.
**Exit:** 10 real shorts, each needing 5 or fewer manual tweaks. The CLI and the app produce identical Timeline JSON.
- [x] Everything above is built. 144 tests pass. `scripts/e2e.sh` passes: pauses removed, −14.0 LUFS, SRT written, export at 209 fps.
- [x] Drafts are deterministic, so the same inputs and seed give byte-identical JSON (tested). The CLI and the app share `DraftPipeline`.
- [ ] Your 10 real shorts with 5 or fewer tweaks each (needs your footage and feedback).

## Phase 2: VOD → many shorts ← current
Chunked transcription, signals (SoundAnalysis, loudness, scene cuts), highlight scoring (heuristic plus an optional local LLM, see ADR 0007), highlights browser, batch export, saliency-based reframing, watch folders.
**Exit:** a 2-hour VOD yields 10 ranked candidates in under 15 minutes, and at least 5 of them are worth posting.

## Phase 3: authoring and generation
"Save as template", JSON template editor, Python worker with ACE-Step music generation, translated caption tracks, ASS export.

## Phase 4: publishing and integrations
YouTube (OAuth with PKCE), TikTok drafts, Instagram via a Cloudflare Worker and R2, calendar/Notion/Sheets, FCPXML/OTIO export.
