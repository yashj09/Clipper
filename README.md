# Clipper

A local-first, automatic video editor for macOS. Built for short-form content, with support for light long-form editing.

**Core loop:** drop in clips → pick a template → Clipper builds an automatic draft (silence and filler cuts, captions, music with ducking, jump-cut zooms, face reframing) → review and tweak it in a pro-style timeline → export with platform loudness.

- Everything runs on-device. No cloud, no subscriptions.
- Native Swift: SwiftUI/AppKit for the UI, AVFoundation + Metal for rendering, Apple Speech/Vision for analysis.
- Requires macOS 26+ on Apple Silicon, Xcode 27+.

## Status

**Phase 1 in progress: clips → templated short.** See [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Build

```bash
# Engine, automation, library and CLI (Swift package)
cd Packages/ClipperKit
swift build -c release            # → .build/release/clipper
swift test                        # needs Fixtures/ for integration tests: ../../scripts/make-fixtures.sh

# macOS app
brew install xcodegen
cd App && xcodegen && open Clipper.xcodeproj      # or: xcodebuild -scheme Clipper -derivedDataPath build build
```

## CLI quick start

```bash
clipper music starter-pack                       # 24 free CC BY tracks (Kevin MacLeod), analyzed for tempo and beats
clipper draft -t talking-head --title "3 tips" take1.mov take2.mov --export
clipper draft -t gameplay match.mov --slot facecam=cam.mov --export
clipper draft -t montage trip/*.mov --title "Lisbon" --export --preset shorts-1080x1920
clipper projects                                  # list drafts
clipper export "3 tips" --preset youtube-1080p     # re-export with another preset
clipper templates --export-to ~/ClipperTemplates   # editable JSON copies of the templates
```

Built-in templates:

| Template | What it does |
|---|---|
| `talking-head` | Tight cuts, bold captions, jump-cut zooms, music ducked under speech |
| `gameplay` | Commentary-driven cuts, optional facecam on top (cut in sync) |
| `montage` | Clips cut on the beat of the music |
| `vlog` | Gentle pause removal, B-roll trimmed to its middle, clean subtitles |

The library lives at `~/Movies/Clipper/Clipper.clipperlib`. You can override it with `--library`.

## Docs

- [Research](docs/research.md): open-source landscape, licenses, chosen and rejected tools.
- [Architecture](docs/ARCHITECTURE.md): modules, data model, rendering and automation pipelines.
- [Phase 0 results](docs/phase0-results.md): de-risking spikes and the design changes they drove.
- [ADRs](docs/adr/): key decisions and why.
- [Licenses](LICENSES.md): dependency allowlist and blocklist.

## Layout

```
Packages/ClipperKit/   Core (model) · Engine (render/export) · Analysis · Automation · Library · clipper CLI
App/                   macOS app (XcodeGen spec + SwiftUI/AppKit sources)
docs/                  research, architecture, ADRs, phase results
Spikes/                Phase 0 experiments
scripts/               fixture generation, ASR scoring
```
