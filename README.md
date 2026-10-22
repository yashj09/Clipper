# Clipper

A local-first, automatic video editor for macOS. Built for short-form content, with support for light long-form editing.

**Core loop:** drop in clips → pick a template → Clipper builds an automatic draft (silence and filler cuts, captions, music with ducking, jump-cut zooms, face reframing) → review and tweak it in a pro-style timeline → export with platform loudness.

- Everything runs on-device. No cloud, no subscriptions.
- Native Swift: SwiftUI/AppKit for the UI, AVFoundation + Metal for rendering, Apple Speech/Vision for analysis.
- Requires macOS 26+ on Apple Silicon, Xcode 27+.

## Status

**Phases 0–4 built** (spikes, clips → short, long recording → many shorts, templates/translation/generated music, publishing/scheduling and FCPXML/OTIO export). See [`docs/ROADMAP.md`](docs/ROADMAP.md).

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
clipper templates export ~/ClipperTemplates        # editable JSON copies of the templates
clipper templates save "3 tips" --name "My style"  # turn an edited project into a reusable template
clipper highlights stream.mov --top 10 --draft --export        # long recording → ranked shorts
clipper highlights stream.mov --llm ollama --model qwen3.5:4b  # optional local-LLM re-ranking
clipper captions translate "3 tips" --to es,fr     # on-device translated caption tracks + subtitle files
clipper music generate "upbeat lo-fi, warm keys" --duration 60  # local AI music (optional worker, ACE-Step)
clipper watch ~/Movies/OBS --template gameplay --export         # auto-draft new recordings
clipper draft -t talking-head take.mov --llm ollama --model qwen3.5:9b --brief   # title, hook, chapters from a local LLM
clipper tag desk.mov office.mov b-roll                                            # mark library clips as cutaway material
clipper draft -t talking-head take.mov --broll-tag b-roll                         # cutaways from your own clips
clipper cover "3 tips" -o cover.jpg                 # best frame of the edit, captions included
clipper publish now "3 tips" --dry-run              # description with chapters and hashtags, nothing posted
```

Built-in templates:

| Template | What it does |
|---|---|
| `talking-head` | Retakes and false starts removed, emphasis zooms, bold captions with emoji, keyword callouts, cold-open hook and title from a local LLM, B-roll from your library, sound effects, music ducked under speech |
| `gameplay` | Commentary-driven cuts, optional facecam on top (cut in sync) |
| `montage` | Clips cut on the beat of the music, dissolves every 4th cut, blurry shots skipped, colour matched |
| `vlog` | Short pauses sped up instead of cut, B-roll cutaways, chapter dips, clean subtitles, colour matched |

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
