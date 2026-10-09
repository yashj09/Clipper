# Dependency licensing policy

Clipper is a personal project that may become open source. Every dependency must be compatible with either outcome, so this file is the gate for adding one.

## Allowed
| License | Condition |
|---|---|
| MIT, BSD-2/3, ISC, Apache-2.0, Zlib | Keep the notice in `ThirdPartyNotices` |
| Unlicense, CC0 | — |
| MPL-2.0 | Modified MPL files must stay MPL |
| LGPL-2.1 / 3.0 | **Separate process or dynamic linking only.** Ship the source offer and the build config. |
| CC-BY 4.0 (model weights, music) | Show attribution in the app and in exported credits |
| Apple SDK frameworks | — |

## Blocked
| What | Why |
|---|---|
| GPL / AGPL code linked into the app (Ultralytics YOLO, essentia, aubio, Etro, Piper ≥ 1.3, MLT GPL modules) | Copyleft would apply to the whole app |
| Non-commercial weights (MusicGen, YuE2, madmom models, F5-TTS, XTTS-v2, Moonshine's legacy non-English models) | Can't be used if the project goes public or commercial |
| Source-available "fair-code" licenses (Twick, OpenVideo editor, Remotion beyond 3 people) | Not open source |
| GPL FFmpeg builds (`--enable-gpl`, libx264/libx265) in a distributed app | Use VideoToolbox encoders instead |

## Current dependencies
| Dependency | License | Used for | Phase |
|---|---|---|---|
| Apple frameworks (AVFoundation, Metal, Speech, Vision, SoundAnalysis, Translation) | SDK | Engine, analysis | 0+ |
| FFmpeg (Homebrew, development only) | GPL build, **dev tool only, not shipped** | Making fixtures, verification | 0 |
| whisper.cpp (spike only) | MIT | Speech-to-text comparison | 0 |
| GRDB.swift | MIT | Library index | 1 |
| swift-argument-parser | Apache-2.0 | CLI | 1 |
