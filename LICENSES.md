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
| uv (user-installed tool, not shipped) | MIT OR Apache-2.0 | Runs the optional Python worker | 3 |
| ACE-Step 1.5 code (`ace-step`, git, pinned) | MIT | Worker `music` extra: local music generation | 3 |
| ACE-Step 1.5 weights (`ACE-Step/Ace-Step1.5`: DiT turbo, VAE, 5Hz LM) | MIT (downloaded on first use, not shipped) | Worker `music` extra | 3 |
| Qwen3-Embedding-0.6B weights (inside the ACE-Step repo) | Apache-2.0 (downloaded on first use) | ACE-Step text encoder | 3 |
| beat_this code + `final0` weights | MIT (weights downloaded on first use) | Worker `beats` extra: beats/downbeats | 3 |
| PyTorch, torchaudio, torchvision, torchcodec, torchao | BSD-3-Clause | Worker (`music`, `beats`) | 3 |
| MLX, mlx-metal, mlx-lm | MIT | Worker `music` (ACE-Step's Apple Silicon backend) | 3 |
| transformers, diffusers, accelerate, peft, tokenizers, safetensors, huggingface_hub, hf-xet, gradio, lightning, modelscope, lycoris-lora, tensorboard | Apache-2.0 | Worker `music` (ACE-Step dependencies) | 3 |
| vector-quantize-pytorch, einops, einx, loguru, rotary-embedding-torch, pytorch-wavelets (DWT, MIT part only) | MIT | Worker `music` / `beats` | 3 |
| numpy, scipy, numba, llvmlite, soundfile, pandas, matplotlib | BSD / PSF | Worker (transitive) | 3 |
| frozendict | LGPL-3.0, **separate process, unmodified, fetched from PyPI by uv, not shipped** | Worker `music` (via einx) | 3 |
| python-soxr | LGPL-2.1+, **separate process, unmodified, fetched from PyPI by uv, not shipped** | Worker `beats` (via beat-this) | 3 |
| pytest | MIT | Worker tests (dev only) | 3 |
