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

## Phase 2: VOD → many shorts ✅ (built; real-use exit pending)
Chunked transcription, signals (SoundAnalysis, loudness, scene cuts), highlight scoring (heuristic plus an optional local LLM, see ADR 0007), highlights browser, batch export, saliency-based reframing, watch folders.
**Exit:** a 2-hour VOD yields 10 ranked candidates in under 15 minutes, and at least 5 of them are worth posting.
- [x] Speed. 30-min 1080p60 VOD, cold: 104 s for transcript + sound events + visual activity + ranking, 224 MB RAM. Extrapolates to about 7 min for 2 h. (Since then: 31 s for the analysis set, see below.) Re-runs come from cache (0 s).
- [x] Local LLM re-ranking: Ollama `qwen3.5:4b` ranked 15 candidates in 44 s, with hook titles and critiques. Cloud models are refused.
- [x] Batch: 3 highlights drafted and exported in 12.5 s total (about 200 fps each, −14 LUFS, SRT).
- [ ] At least 5 of 10 worth posting on a real VOD of yours (needs your recording and judgement).

## Phase 3: authoring and generation ✅
- [x] **Save as template** (`TemplateBuilder`): infers slots (role, fill including linked facecams, placement), elements (whole/opening/closing, `{title}`), styles, caption/duck/punch-in rules and music level. Round-trip tested. CLI `templates save|validate|export`; app sheet plus a JSON editor with live validation.
- [x] **Translated caption tracks** (Apple Translation, on-device). Whole sentences are translated, then spread over pages by word share. Hidden by default; the app's Captions menu chooses the burned-in language. Sidecars `<name>.<lang>.srt|vtt|ass`. Right-to-left and CJK layout.
- [x] **ASS export** with styles and karaoke `\k` timing (master presets).
- [x] **Generated music** (ACE-Step 1.5, MIT, MLX on Apple Silicon) through the optional Python worker (`worker/`, uv, JSON-RPC over stdio). About 10–20 s per 30 s once loaded, 16 GB peak, 6.3 GB weights on first use. CLI `music generate`; app Music ▸ Generate.
- [x] Fixed: SwiftPM recorded the deployment target as the binary's SDK, which hid installed translation languages from the CLI.

## Phase 4: publishing and integrations ✅ (built; live accounts pending your developer apps)
- [x] **Bring-your-own-keys publishing** (Keychain, no server). Details in [publishing.md](publishing.md).
  - YouTube: resumable upload plus captions.
  - TikTok: inbox drafts, chunked upload.
  - Instagram Reels: temporary R2/S3 object behind a SigV4 presigned URL, then the Graph API publishes it. No Cloudflare Worker needed.
  - OAuth loopback with PKCE: RFC 7636 vector, plus TikTok's hex variant.
  - All of this is tested against mock servers only.
- [x] **Publishing queue**, `publish now|schedule|run-due`, an optional LaunchAgent, and an **.ics calendar feed** for Apple/Google Calendar and Notion subscriptions.
- [x] **FCPXML 1.10/1.11** (validated against Apple's DTDs) and **OTIO** export. The OTIO file is read back by opentimelineio 0.18.1. `clipper interchange`; the app's Export ▸ "Open in another editor".
- [x] App: Accounts settings, Publish sheet, Publishing sidebar, and watch folders with auto-draft.
- [x] Fixed: an unanchored `models/` ignore rule had kept `App/Clipper/Models/` out of git. A fresh clone now builds.
- [x] Facts corrected from official docs: YouTube no longer forces unverified projects to private; Instagram needs no App Review for your own account; Reels via the API are 3 s–15 min and at most 300 MB.
- [ ] First real upload per platform, once you've created the developer apps (`clipper publish connect <platform> --help-setup`).
- [ ] Notion/Sheets APIs: not built. The .ics feed covers calendar views without accounts.

## After Phase 4: editor and performance (2026-10-15)
- [x] **Manual editor**: rebindable keyboard shortcuts (Settings ▸ Shortcuts), media browser with drag-and-drop and Q/W/E/D edits, Add Text, In/Out range delete, J/K/L shuttle, previous/next edit, copy/paste/duplicate, trim to playhead, nudge, speed (25–400%), keyframes in the inspector with markers on clips, right-click menu, and **re-draft keeping your edits**. Guide: [editor.md](editor.md).
- [x] **Review #23 fixed**: a loudness-normalised export builds the composition and decodes/mixes the audio once (captured to a temporary CAF while measuring).
- [x] **Shared audio decode** for speech, transcript, loudness and sound events. 30-min VOD highlights set, cold: 36.9 s → 31.2 s (−15%).
- [x] **Proxies**: 720p HEVC made in the background for heavy media (beyond 1080p, ProRes, over 20 min); 6.5× realtime; `clipper proxy`; the preview falls back to originals when a proxy is missing.
- [x] Debug-only scripted smoke tests for the editor (real key events, scratch library).
- [ ] Your check: drag from the browser onto the timeline with the mouse (not scriptable without Accessibility permission).
