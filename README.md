# Clipper

A local-first, automatic video editor for macOS. Built for short-form content, with support for light long-form editing.

**Core loop:** drop in clips → pick a template → Clipper builds an automatic draft (silence cuts, captions, music, ducking, reframing) → review and tweak it in a pro-style timeline → export.

- Everything runs on-device. No cloud, no subscriptions.
- Native Swift: SwiftUI/AppKit for the UI, AVFoundation and Metal for rendering, Apple Speech/Vision/Translation for analysis.
- Requires macOS 26 or later on Apple Silicon.

## Status

**Phase 0: research, architecture and de-risking spikes.** See [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Docs

- [Research](docs/research.md): open-source landscape, licenses, and the tools we chose or rejected.
- [Architecture](docs/ARCHITECTURE.md): modules, data model, rendering and automation pipelines.
- [ADRs](docs/adr/): key decisions and the reasons for them.
- [Licenses](LICENSES.md): dependency allowlist and blocklist.

## Layout

```
docs/        research, architecture, ADRs, phase results
Spikes/      Phase 0 throwaway experiments (SwiftPM)
scripts/     fixture generation and helper scripts
Fixtures/    generated test media (gitignored; regenerate via scripts/make-fixtures.sh)
```
