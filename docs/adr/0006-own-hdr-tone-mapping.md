# ADR 0006: Do our own HDR→SDR tone mapping in the compositor

**Status:** Accepted, 2026-10-10 (from Phase 0 spike S2)

## Context
When a custom compositor declares SDR sources, AVFoundation converts HDR to SDR for us. S2 showed that the AVPlayer (preview) path and the AVAssetReader (export) path produce **different** results for HLG, the iPhone's default HDR format: 18–20 dB PSNR between them. That breaks the "preview equals export" principle.

## Decision
- Give the video composition the source's native HDR colour space, so the compositor receives untouched half-float BT.2020 HLG/PQ frames.
- Tone-map in our Metal shader using luminance-based curves fitted to Apple's SDR rendering:
  - HLG: `Y^0.654`
  - PQ: an extended Reinhard curve at 180 nits with exponent 0.7.
- Tag the output buffers Rec.709 ourselves.

## Consequences
- Preview and export are bit-identical for HDR sources, verified.
- We own the tone curve. It needs visual tuning on real iPhone footage, and it gives us a hook for a future "HDR export" mode.
- Mixed SDR/HDR timelines need a per-layer transfer function; the source's format description tells us which.
