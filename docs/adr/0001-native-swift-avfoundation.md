# ADR 0001: Native Swift + AVFoundation instead of web/Rust stacks

**Status:** Accepted, 2026-10-10

## Context
We need a desktop editor that runs locally. It must have a pro-style multi-track timeline, frame-accurate preview whose output matches the export, ProRes/HEVC export with alpha, HDR iPhone footage support, and on-device ML. The user targets macOS 26+ only.

## Decision
Build a native macOS app: SwiftUI shell, an AppKit/CALayer timeline, and an AVFoundation engine with a custom Metal compositor.

## Consequences
- **Gains:** frame-accurate playback, seeking, A/V sync, hardware decode and encode, ProRes/HEVC with alpha, and on-device Speech/Vision/Translation/SoundAnalysis, all without extra libraries.
- **Cost:** macOS only. Moving to another OS would mean a rewrite.
- **Rejected:**
  - Tauri + React + Rust: we would have to build the playback engine ourselves.
  - Electron + Remotion: weak for long-form video and pro codecs.
  - MLT/Qt: slower UI work, and its GPL modules.
