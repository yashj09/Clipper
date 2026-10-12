# Research: open-source landscape (verified October 2026)

This is a summary of the Phase 0 research. Licenses and maintenance status were checked against GitHub and npm on 2026-10-10. It records why each component was chosen or rejected, so later decisions can refer back to it.

## 1. Rendering and editing engines

| Candidate | License | Status | Verdict for Clipper |
|---|---|---|---|
| **AVFoundation** (Apple) | macOS SDK | Current | **Chosen.** Multi-track composition, frame-accurate preview, ProRes/HEVC (including alpha) export, and the VideoToolbox hardware encoder. A custom `AVVideoCompositing` compositor serves both preview and export. |
| FFmpeg 8.1 | LGPL-2.1+ (GPL if built with `--enable-gpl`) | Very active | **Used narrowly**: import fallback (webm, mkv, AV1, VP9) and verification tools. Before distribution, bundle an LGPL build. |
| MLT 7.42 / `melt` | LGPL core, GPL modules | Monthly releases | Strongest open engine (it powers Shotcut and Kdenlive). We don't use it: AVFoundation covers this on macOS 26+. |
| Shotcut / Kdenlive | GPL-3.0 | Very active | Reference implementations for timeline UX, proxies and keyframes. |
| libopenshot 1.0 | LGPL-3.0 | Revived with OpenShot 4.0 | Its JSON project format is a useful reference for templates. |
| GES (GStreamer) | LGPL | Lightly maintained | Not used. |
| Remotion | Source-available; company license required for teams of 4+ | Very active | Not used. Needs Chromium, and per-render fees if this ever becomes a product. |
| Revideo | MIT | Revived July 2026 | Not used. Uncertain sustainability. |
| mediabunny / WebCodecs | MPL-2.0 | Very active | Irrelevant, because we're not building a web UI. |
| OpenTimelineIO | Apache-2.0 | Active | **Planned for interchange** (Phase 4). Our model should map to OTIO. |
| OpenCut | MIT | Mid-rewrite (Rust + GPUI) | Watch only. |
| Gausian (Rust editor) | Apache-2.0 | Active | Reference only. |
| Olive, Motion Canvas, editly, Etro | various | Dead, dormant, or GPL | Avoid. |

There is no healthy open-source equivalent of Shotstack's JSON video format. **We define our own JSON schema** (see ARCHITECTURE.md).

## 2. Automation and analysis

| Job | Choice | License | Notes |
|---|---|---|---|
| Speech-to-text (word timestamps) | **Apple SpeechAnalyzer / SpeechTranscriber** (macOS 26) | SDK | On-device. Phase 0 spike S3 compares it against whisper.cpp. |
| Fallback speech-to-text | whisper.cpp | MIT | Metal and Core ML support. Word timestamps are experimental. |
| Speech-to-text, rejected | faster-whisper (no Metal), WhisperX (no MPS), Parakeet (English/European only, CC-BY weights) | MIT / BSD / Apache | Kept as possible alternatives. |
| Silence / voice activity | Word gaps + RMS level, optionally Silero VAD | MIT | auto-editor (Unlicense) used as a reference only. |
| Scene cuts | Histogram difference in Swift; PySceneDetect as an option | BSD-3 | `ffmpeg scdet` for verification. |
| Laughter / applause / cheering | **Apple SoundAnalysis** built-in classifier | SDK | Highlight signal for Phase 2. |
| Faces / saliency / tracking | **Apple Vision** | SDK | Avoid Ultralytics YOLO (AGPL-3.0). MediaPipe (Apache) is the backup. |
| Highlight scoring | MLX Swift + Qwen3-14B 4-bit (about 9 GB) | MIT / Apache | Map-reduce over the transcript, constrained JSON output. |
| Beat tracking | Swift spectral flux + autocorrelation; **beat_this** (MIT, code and weights) in the Python worker | MIT | Avoid madmom (non-commercial models), essentia (AGPL), aubio (GPL). |
| Music generation | **ACE-Step 1.5** | MIT | Avoid MusicGen (CC-BY-NC) and YuE2 (CC-BY-NC). Stable Audio 3 is free only under $1M annual revenue. |
| Bundled music | Incompetech (CC-BY 4.0, machine-readable catalog), FreePD (CC0) | CC | Pixabay causes Content ID claims. YouTube Audio Library has no API. |
| Loudness | Our own BS.1770 implementation; two-pass to −14 LUFS, true peak −1 dBTP | — | Check with `ffmpeg ebur128`. |
| Caption translation | **Apple Translation framework** | SDK | On-device. |
| Text-to-speech (later) | Kokoro-82M | Apache-2.0 | Avoid Piper (now GPL), XTTS, F5 (non-commercial). |

## 3. Publishing APIs (for Phase 4)

| Platform | Desktop OAuth | Restrictions until the app passes review | Server needed? |
|---|---|---|---|
| YouTube | Loopback redirect + PKCE (desktop client) | **Uploads are forced to private** until the compliance audit passes. Uploads have their own quota bucket (100 per day). | No |
| TikTok | Loopback + PKCE (hex SHA-256) | **Posts are forced to private (SELF_ONLY); at most 5 users per day.** Audit takes 2–6 weeks. Drafts/inbox upload also works. | No (the client secret is better kept behind a proxy) |
| Instagram Reels | Instagram Login (no Facebook Page needed) | **Corrected 2026-10-13:** App Review and business verification are needed only for Advanced Access (other people's accounts). Standard Access covers accounts with a role on your app, so personal publishing needs no review. 100 posts per 24 h. Reels via the API: 3 s–15 min, at most 300 MB. | **Needs a public HTTPS `video_url`.** Clipper uploads to your R2/S3 bucket and passes a presigned URL, so no server is needed. |
| Facebook Reels | Facebook Login | 30 per day per Page | No |
| X | PKCE | Pay per use, about $0.015 per post | No |
| Snapchat | Partners only | — | Out of scope |

Avoid browser-automation uploaders such as social-auto-upload: they violate platform terms and risk the account.

## 4. Why native Swift instead of Tauri/Electron
- Tauri on macOS uses WKWebView. Full WebCodecs support there needs macOS 26, and we would still have to build playback, A/V sync and seeking ourselves.
- Electron is heavier. Remotion-style web compositors are weak for long-form and pro codecs.
- AVFoundation provides preview, playback, frame-accurate seeking and export on one engine. That gives what-you-see-is-what-you-get output, ProRes/HEVC with alpha, and HDR handling.
- The cost: macOS only. The user accepted this.

## 5. Licensing rules (see /LICENSES.md)
- Allowed: MIT, BSD, ISC, Apache-2.0, Unlicense/CC0, MPL-2.0 (file-level), LGPL (dynamic linking only), and model weights licensed CC-BY with attribution.
- Blocked: GPL/AGPL code linked into the app, and non-commercial (NC) model weights.
