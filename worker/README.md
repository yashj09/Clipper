# clipper-worker

Clipper's optional Python worker (ADR 0005). Some tools only exist in Python: local music generation (ACE-Step) and
beat tracking (beat_this). They run here, in a separate process. Clipper talks to that process with JSON-RPC 2.0 over
stdio. The app never requires the worker. Swift fallbacks exist for beats, and generated music is an extra.

## Install

You need [uv](https://docs.astral.sh/uv/) (`brew install uv`). The project pins Python 3.12 (`.python-version`).

```sh
cd worker
uv sync                    # base worker: standard library only, a few MB
uv sync --extra music      # + ACE-Step 1.5 music generation (~1.3 GB venv: torch, MLX, transformers, ...)
uv sync --extra beats      # + beat_this beat/downbeat tracking (torch, soxr)
uv sync --all-extras       # everything (~1.4 GB)
uv run pytest              # protocol tests (they don't load any model)
```

Clipper launches the worker with
`uv run --project <worker> --frozen --quiet [--extra music] python -m clipper_worker`. uv installs a missing extra on
first launch, so the first call after enabling a feature can take a few minutes.

Resolution is limited to macOS on Apple Silicon (`[tool.uv] environments`). ACE-Step's Linux and Windows pins point to
CUDA builds of torch.

### Model weights

Weights are downloaded on first use into `$CLIPPER_MODELS`, which defaults to
`~/Library/Application Support/Clipper/models`.

| Feature | What is downloaded | Size | Where |
|---|---|---|---|
| Music (default, `thinking: false`) | `ACE-Step/Ace-Step1.5`: `acestep-v15-turbo` (DiT, 4.8 GB), `vae` (0.3 GB), `Qwen3-Embedding-0.6B` (text encoder, 1.2 GB) | **6.3 GB** | `models/ace-step/checkpoints/` |
| Music with `thinking: true` | + `acestep-5Hz-lm-1.7B` (language model) | +3.8 GB | same |
| Beats | beat_this `final0` checkpoint | 77 MB | `models/torch-hub/` |

The first `generate_music` call reports download progress in bytes. An interrupted download resumes on the next call.

## Protocol

Messages are newline-delimited, with one JSON object per line in each direction. stdout carries only protocol
messages. The worker redirects fd 1 to stderr at startup, so library `print`s can't corrupt the stream. All logs go to
stderr.

| Method | Params | Result |
|---|---|---|
| `ping` | – | `{version, python, torch, mps}` |
| `capabilities` | – | `{music_generation, music_model, music_model_downloaded, beat_this, models_dir, packages}`. Cheap: checks installed packages without importing them. |
| `generate_music` | `{prompt, duration_s (10–600), out_path (.wav/.flac, absolute), seed?=0, bpm?, instrumental?=true, lyrics?, thinking?=false, steps?=8, model?, device?}` | `{path, duration_s, sample_rate, channels, model, seed, bpm, seconds_elapsed, load_seconds, stats: {peak_rss_mb, mlx_peak_mb, mps_driver_mb}}` |
| `beats` | `{path}` | `{beats: [s], downbeats: [s], bpm, model}` |
| `shutdown` | – | `null`, then the worker exits after cancelling in-flight work |

- **Progress** (worker → client notification): `{"jsonrpc":"2.0","method":"progress","params":{"id":<request id>,"fraction":0..1,"message":"..."}}`.
- **Cancel** (client → worker notification): `{"jsonrpc":"2.0","method":"$/cancel","params":{"id":<request id>}}`. Cancellation is cooperative: ACE-Step stops at its next progress point and the request fails with code -32800. A weight download can't be interrupted. Clipper kills the worker if it doesn't acknowledge within a few seconds, and the download resumes next time.
- **EOF on stdin**: the worker finishes requests it has already received, then exits. It also exits if its parent dies.
- **Errors**:

| Code | Meaning |
|---|---|
| -32700 / -32600 / -32601 / -32602 / -32603 | JSON-RPC parse error / invalid request / unknown method / invalid params / internal error |
| -32001 | Feature not installed. `data.extra` names the extra to install. |
| -32002 | Generation failed (model load or ACE-Step error) |
| -32800 | Request cancelled |

Environment variables: `CLIPPER_MODELS` (weights directory), `CLIPPER_MUSIC_MODEL` (DiT variant, default
`acestep-v15-turbo`), `CLIPPER_MUSIC_DEVICE` (`auto` | `mps` | `cpu`), `CLIPPER_WORKER_LOG` (log level), plus the
memory settings under Performance.

## How Clipper uses it

- `ClipperAnalysis/Worker/PythonWorker.swift` (`PythonWorker` actor) does the following:
  - Starts the worker lazily and restarts it on the next call after a crash.
  - Matches responses to requests by id and routes `progress` to per-call handlers.
  - Applies per-call timeouts. A timeout bounds silence, not total time: each `progress` restarts it, so a long download or generation never times out while it is reporting.
  - Maps task cancellation to `$/cancel`, and terminates a worker that ignores it.
  - Provides `shutdown()`.
  - Finds the project through `CLIPPER_WORKER_DIR`, `Contents/Resources/worker`, or by walking up from the executable.
- `ClipperAnalysis/Worker/MusicGenerator.swift` calls `generate_music`. It then runs `MusicAnalyzer` (Swift beat
  tracker and energy) on the result and returns a `MusicTrack`. The track has
  `license: .generated(model: "ACE-Step 1.5 (acestep-v15-turbo)")`, moods mapped from the prompt's words onto
  Clipper's canonical moods, and genre tags.

## Performance (M4 Pro, 24 GB, macOS 26)

All numbers are for a 30 s instrumental, 48 kHz stereo, with `acestep-v15-turbo` at 8 steps. The DiT and VAE run in
native MLX; the text encoder and condition encoder run in PyTorch on MPS. During these runs the Mac was also running
browsers and editors, with 16–18 GB of swap already in use, so times vary a lot from run to run.

| | ACE-Step defaults | Clipper worker (defaults below) |
|---|---|---|
| Peak memory footprint (`/usr/bin/time -l`) | **31.4 GB** (swapping on 24 GB) | **16.1 GB** |
| Footprint while loaded and idle | – | 11.4 GB |
| Model load (weights already on disk) | 112 s | 26–56 s |
| Diffusion | 6.5 s/step | 0.5–1.0 s/step on a quiet machine, up to 3.7 s/step under memory pressure |
| VAE decode | 12.6–25 s | 2.9–4.4 s |
| **Generation time per 30 s of audio** (warm) | 117 s | **10.3 s best**, 16–21 s typical, 36–70 s on a busy machine |

Other measurements:
- First-run download: 6.3 GB in 21 min on this connection.
- Swift live test (`CLIPPER_LIVE_MUSIC=1`), 10 s track: 165 s end to end, covering `uv run` startup, model load and generation. Clipper's beat tracker measured 90.07 BPM for a "90 bpm" prompt.

The worker departs from ACE-Step's defaults in four ways. None of them changes the output for a given seed in any
audible way.

1. **Lean DiT load** (`_init_mlx_dit_lean`). Upstream keeps the PyTorch DiT in float32 on MPS and also builds a float32 MLX copy beside it. The worker converts one tensor at a time straight to MLX, releases each PyTorch tensor as it goes, and moves the PyTorch decoder to the meta device. text2music only runs the MLX decoder.
2. **bf16 MLX DiT weights.** The checkpoint is bf16, so this is lossless. Measured against float32 weights for the same seed, the output is bit-identical (SNR 247 dB). `CLIPPER_MUSIC_MLX_DTYPE=float32` costs +3 GB.
3. **fp16 MLX VAE** (`ACESTEP_MLX_VAE_FP16=1`). Measured at 56–60 dB SNR against float32 decode for the same seed.
4. **1 GB MLX buffer cache.** Without a limit, MLX keeps every VAE activation buffer it frees. The decode then grew the footprint from 14 to 26 GB and slowed to 8–19 s. Caches are also released after each request.

Settings: `CLIPPER_MUSIC_LEAN_LOAD=0` restores upstream loading. `CLIPPER_MUSIC_MLX_CACHE_GB` sets the cache limit.
`CLIPPER_MUSIC_VAE_CHUNK` sets the VAE tile size in latent frames (default 512).

A loaded worker holds about 11 GB. Clipper should call `PythonWorker.shutdown()` once it has finished generating.

## Licences

### Models

| Model | Licence | Notes |
|---|---|---|
| ACE-Step 1.5 (`ACE-Step/Ace-Step1.5`: DiT turbo, VAE, 5Hz LM 1.7B) | **MIT** (Hugging Face card `license: mit`; repo LICENSE MIT, © 2026 ACEStep) | Code and weights. Commercial use OK. |
| Qwen3-Embedding-0.6B (bundled in that repo as ACE-Step's text encoder) | Apache-2.0 (Qwen) | |
| beat_this `final0` | MIT (code and weights, per the CPJKU README) | |

### Python packages (resolved by `uv.lock`)

Only permissive licences are used, plus two LGPL packages that are allowed here. Each runs unmodified, in this
separate process, and is downloaded from PyPI on the user's machine rather than shipped with Clipper.

| Package | Licence | Pulled in by |
|---|---|---|
| ace-step 1.5.0 (git, pinned commit) | MIT | `music` |
| torch, torchaudio, torchvision, torchcodec, torchao | BSD-3-Clause | `music`, `beats` |
| mlx, mlx-metal, mlx-lm | MIT | `music` (ACE-Step's Apple Silicon backend) |
| transformers, diffusers, accelerate, peft, tokenizers, safetensors, huggingface_hub, hf-xet, sentencepiece | Apache-2.0 | `music` |
| gradio, gradio_client, lightning, pytorch-lightning, torchmetrics, tensorboard, modelscope, lycoris-lora | Apache-2.0 | `music` (ACE-Step's UI/training deps; installed but not used by the worker) |
| vector-quantize-pytorch, einops, einx, loguru, pytorch-wavelets (DWT part, which is what ACE-Step uses), rotary-embedding-torch, fastapi, pydantic | MIT | `music` / `beats` |
| numpy, scipy, numba, llvmlite, soundfile, pandas, matplotlib, uvicorn, starlette, click | BSD / PSF / Apache (LLVM exception) | `music` |
| certifi, tqdm, orjson | MPL-2.0 (some dual MIT/Apache) | transitive |
| **frozendict** 2.4.7 | **LGPL-3.0** | einx ← vector-quantize-pytorch ← ace-step. Allowed: separate process, unmodified. |
| **soxr** (python-soxr) 1.1.0 | **LGPL-2.1+** | beat-this. Allowed: separate process, unmodified. |
| beat-this 1.1.0 | MIT | `beats` |
| pytest | MIT | dev group |

There are no GPL/AGPL packages and no non-commercial weights. pytorch-wavelets is marked "Free To Use But
Restricted" on PyPI. Its DWT code, which ACE-Step's DCW loader imports, is MIT. The restricted part is its DTCWT
code, derived from Kingsbury's MATLAB toolbox, and it is never imported. To re-check after changing dependencies,
list `License-Expression` / `Classifier: License` from `importlib.metadata` in the venv.
