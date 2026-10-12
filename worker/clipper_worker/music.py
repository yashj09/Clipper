"""Instrumental music generation with ACE-Step 1.5 (https://github.com/ace-step/ACE-Step-1.5, MIT code and weights).

The DiT ("acestep-v15-turbo", 8 steps) and the VAE run in ACE-Step's native MLX backend on Apple Silicon; the text
and condition encoders run in PyTorch on MPS. The worker loads them leaner than upstream (see `_init_mlx_dit_lean`
and `_limit_vae_memory`; README "Performance"). The optional 5 Hz language model ("thinking") is off by default: it
adds minutes and memory and mostly helps songs with lyrics.

Weights come from the `ACE-Step/Ace-Step1.5` Hugging Face repo (MIT) and are downloaded on first use into
`$CLIPPER_MODELS/ace-step/checkpoints`: DiT + VAE + text encoder (~6.3 GB) always, the 1.7B LM (~3.8 GB) only for
`thinking` requests.
"""

from __future__ import annotations

import logging
import os
import resource
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Dict, Optional

from .methods import param
from .paths import models_dir
from .protocol import GENERATION_FAILED, INVALID_PARAMS, Cancelled, RPCError, RequestContext

log = logging.getLogger("clipper_worker.music")

MODEL_FAMILY = "ACE-Step 1.5"
DEFAULT_DIT = "acestep-v15-turbo"
MIN_DURATION, MAX_DURATION = 10.0, 600.0


def ace_root() -> Path:
    return models_dir() / "ace-step"


def checkpoints_dir() -> Path:
    return ace_root() / "checkpoints"


def _configure_env() -> None:
    # ACE-Step resolves its checkpoints and timing caches from these; keep everything under Clipper's models dir.
    root = ace_root()
    root.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("ACESTEP_PROJECT_ROOT", str(root))
    os.environ.setdefault("ACESTEP_CHECKPOINTS_DIR", str(checkpoints_dir()))
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    # Half-precision MLX VAE decode: half the VAE memory; measured 56-60 dB SNR against float32 for the same seed.
    os.environ.setdefault("ACESTEP_MLX_VAE_FP16", "1")


MAIN_REPO = "ACE-Step/Ace-Step1.5"
# What text2music needs without the LM: DiT, VAE and text encoder (~6.3 GB). The 1.7B LM (~3.8 GB) is fetched only
# when a request asks for `thinking`.
CORE_COMPONENTS = ("acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B")
LM_COMPONENT = "acestep-5Hz-lm-1.7B"


def _has_weights(component: str) -> bool:
    d = checkpoints_dir() / component
    return d.is_dir() and any(d.glob("*.safetensors"))


def main_model_downloaded() -> bool:
    return all(_has_weights(c) for c in CORE_COMPONENTS)


def ensure_weights(components: tuple, ctx: RequestContext, start: float, end: float) -> bool:
    """Downloads the missing components of the ACE-Step 1.5 repo, reporting bytes on disk as progress.

    Returns True if anything was downloaded. Interrupted downloads resume on the next call (Hugging Face cache).
    """
    missing = [c for c in components if not _has_weights(c)]
    if not missing:
        return False
    from huggingface_hub import HfApi, snapshot_download

    ckpt = checkpoints_dir()
    ckpt.mkdir(parents=True, exist_ok=True)
    info = HfApi().model_info(MAIN_REPO, files_metadata=True)
    wanted = [s for s in info.siblings if s.rfilename.split("/")[0] in missing or "/" not in s.rfilename]
    total = sum(s.size or 0 for s in wanted) or 1
    staging = ckpt / ".cache" / "huggingface" / "download"

    def on_disk() -> int:
        done = 0
        for s in wanted:
            f = ckpt / s.rfilename
            if f.exists():
                done += s.size or 0
        for c in missing:
            for partial in (staging / c).glob("*.incomplete") if (staging / c).is_dir() else ():
                done += partial.stat().st_size
        return done

    stop = threading.Event()

    def report() -> None:
        while not stop.wait(1.0):
            done = on_disk()
            ctx.progress(start + (end - start) * min(done / total, 0.999),
                         f"Downloading ACE-Step 1.5 weights ({done / 1e9:.1f} of {total / 1e9:.1f} GB, first run only)")

    log.info("downloading %s from %s (%.1f GB) into %s", missing, MAIN_REPO, total / 1e9, ckpt)
    ctx.progress(start, f"Downloading ACE-Step 1.5 weights ({total / 1e9:.1f} GB, first run only)")
    reporter = threading.Thread(target=report, name="download-progress", daemon=True)
    reporter.start()
    try:
        snapshot_download(MAIN_REPO, local_dir=str(ckpt),
                          allow_patterns=[f"{c}/*" for c in missing] + [s.rfilename for s in wanted if "/" not in s.rfilename])
    finally:
        stop.set()
        reporter.join()
    # ACE-Step keeps the authoritative model code in its package and syncs it into checkpoint dirs.
    from acestep.model_downloader import _CHECKPOINT_TO_VARIANT, _sync_model_code_files

    for c in missing:
        if c in _CHECKPOINT_TO_VARIANT:
            _sync_model_code_files(c, ckpt)
    ctx.progress(end, "Weights downloaded")
    return True


class _Engine:
    """Loaded ACE-Step handlers. One generation runs at a time (the models aren't re-entrant)."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.dit = None
        self.dit_config: Optional[str] = None
        self.device: Optional[str] = None
        self.llm = None
        self.llm_loaded = False

    def load(self, dit_config: str, device: str, ctx: RequestContext) -> float:
        """Loads the DiT pipeline (downloading weights first if needed). Returns the fraction of overall progress
        used so far, so generation progress continues from there."""
        if self.dit is not None and self.dit_config == dit_config and self.device == device:
            return 0.0
        _configure_env()
        components = tuple(dict.fromkeys((dit_config, *CORE_COMPONENTS[1:])))
        downloaded = ensure_weights(components, ctx, 0.0, 0.5)
        base = 0.5 if downloaded else 0.0
        ctx.progress(base, "Loading ACE-Step 1.5")
        from acestep.handler import AceStepHandler
        from acestep.llm_inference import LLMHandler

        class Handler(AceStepHandler):
            # ACE-Step's own pre-check insists on the whole 10 GB repo (including the LM); `ensure_weights` has
            # already fetched exactly what this pipeline loads.
            def _ensure_models_present(self, **kwargs: Any) -> None:
                return None

            def _init_mlx_dit(self, compile_model: bool = False) -> bool:
                if os.environ.get("CLIPPER_MUSIC_LEAN_LOAD", "1") == "0":
                    return super()._init_mlx_dit(compile_model=compile_model)
                return _init_mlx_dit_lean(self, compile_model)

        started = time.monotonic()
        dit = Handler()
        status, ok = dit.initialize_service(project_root=str(ace_root()), config_path=dit_config, device=device)
        if not ok:
            raise RPCError(GENERATION_FAILED, f"ACE-Step failed to load: {status}")
        _limit_vae_memory(dit)
        log.info("ACE-Step loaded in %.1fs: %s", time.monotonic() - started, status)
        self.dit, self.dit_config, self.device = dit, dit_config, device
        if self.llm is None:
            self.llm = LLMHandler()
        return base + 0.05

    def load_lm(self, ctx: RequestContext, base: float) -> float:
        if self.llm_loaded:
            return base
        downloaded = ensure_weights((LM_COMPONENT,), ctx, base, base + 0.3)
        base += 0.3 if downloaded else 0.0
        ctx.progress(base, "Loading ACE-Step 5Hz LM")
        status, ok = self.llm.initialize(checkpoint_dir=str(checkpoints_dir()), lm_model_path=LM_COMPONENT,
                                         backend="mlx", device="auto", offload_to_cpu=False, dtype=None)
        if not ok:
            raise RPCError(GENERATION_FAILED, f"ACE-Step LM failed to load: {status}")
        self.llm_loaded = True
        return base + 0.05


_engine = _Engine()


def _limit_vae_memory(handler: Any) -> None:
    """Bound the MLX VAE decode's transient memory, the largest peak of a generation.

    Without a cache limit, MLX keeps every freed VAE activation buffer for reuse. Measured on a 30 s track, footprint
    climbed from 14 to 26 GB during decode, and the decode itself slowed to 8-19 s under swap. With a 1 GB cache the
    peak is 16 GB and decode takes about 3 s.
    """
    import mlx.core as mx

    # Latent frames per VAE tile (25 per second of audio); ACE-Step's default is 512 and its floor 192.
    handler.mlx_vae_chunk_size = int(os.environ.get("CLIPPER_MUSIC_VAE_CHUNK", "512"))
    mx.set_cache_limit(int(float(os.environ.get("CLIPPER_MUSIC_MLX_CACHE_GB", "1")) * (1 << 30)))


def _release_caches() -> None:
    """Return cached GPU buffers to the system between requests (an idle worker otherwise holds them)."""
    import mlx.core as mx
    import torch

    mx.clear_cache()
    if torch.backends.mps.is_available():
        torch.mps.empty_cache()


def _init_mlx_dit_lean(handler: Any, compile_model: bool) -> bool:
    """ACE-Step's MLX DiT init, without holding two float32 copies of the DiT.

    Upstream (`MlxDitInitMixin._init_mlx_dit` + `dit_convert.convert_decoder_weights`) keeps the PyTorch decoder
    (float32 on MPS) and builds a float32 MLX copy next to it: ~2 × 7 GB for this 2B model, which pushes a 24 GB Mac
    into heavy swap (measured: 31 GB peak footprint, 6.5 s per diffusion step). Here each tensor goes straight to
    MLX in bfloat16 (the checkpoint's own precision) and its PyTorch storage is released immediately; afterwards the
    PyTorch decoder lives on the meta device. text2music only runs the MLX decoder (the PyTorch one is used for lyric
    scoring/timestamps, which the worker doesn't expose). The key/layout rules mirror `convert_decoder_weights` at the
    pinned ACE-Step commit. `CLIPPER_MUSIC_LEAN_LOAD=0` restores upstream behaviour.
    """
    import gc

    import mlx.core as mx
    import torch
    from acestep.models.mlx import mlx_available

    if not mlx_available():
        return False
    from acestep.models.mlx.dit_model import MLXDiTDecoder

    dtype = mx.float32 if os.environ.get("CLIPPER_MUSIC_MLX_DTYPE") == "float32" else mx.bfloat16
    decoder = handler.model.decoder
    mlx_decoder = MLXDiTDecoder.from_config(handler.config)
    weights = []
    keys = set(decoder.state_dict().keys())  # what upstream converts (parameters + persistent buffers)
    tensors = dict(decoder.named_parameters(remove_duplicate=False))
    tensors.update(decoder.named_buffers(remove_duplicate=False))
    for i, (key, tensor) in enumerate(tensors.items()):
        if key not in keys or "rotary_emb" in key:
            continue
        value = tensor.detach().to("cpu").float().numpy()
        new_key = key
        if key.startswith("proj_in.1."):  # Sequential(Lambda, Conv1d, Lambda) -> bare Conv1d
            new_key = key.replace("proj_in.1.", "proj_in.")
            if new_key.endswith(".weight"):
                value = value.swapaxes(1, 2)  # Conv1d [out, in, K] -> [out, K, in]
        elif key.startswith("proj_out.1."):  # Sequential(Lambda, ConvTranspose1d, Lambda)
            new_key = key.replace("proj_out.1.", "proj_out.")
            if new_key.endswith(".weight"):
                value = value.transpose(1, 2, 0)  # ConvTranspose1d [in, out, K] -> [out, K, in]
        array = mx.array(value)
        if array.dtype == mx.float32:
            array = array.astype(dtype)
        mx.eval(array)
        weights.append((new_key, array))
        tensor.data = torch.empty(0, dtype=tensor.dtype, device=tensor.device)  # release the PyTorch storage now
        del value
        if i % 64 == 63 and torch.backends.mps.is_available():
            torch.mps.empty_cache()
    mlx_decoder.load_weights(weights)
    converted = len(weights)
    del weights
    mx.eval(mlx_decoder.parameters())
    mlx_decoder.materialize_static_buffers()
    decoder.to("meta")
    gc.collect()
    if torch.backends.mps.is_available():
        torch.mps.empty_cache()
    handler.mlx_decoder = mlx_decoder
    handler.use_mlx_dit = True
    handler.mlx_dit_compiled = compile_model
    log.info("MLX DiT ready (%d tensors, %s); PyTorch DiT copy released", converted, dtype)
    return True


def _peak_memory() -> Dict[str, float]:
    stats: Dict[str, float] = {"peak_rss_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6}  # bytes on macOS
    try:
        import mlx.core as mx

        stats["mlx_peak_mb"] = mx.get_peak_memory() / 1e6
    except Exception:  # noqa: BLE001 - optional stats
        pass
    try:
        import torch

        if torch.backends.mps.is_available():
            stats["mps_driver_mb"] = torch.mps.driver_allocated_memory() / 1e6
    except Exception:  # noqa: BLE001
        pass
    return stats


def generate(params: Dict[str, Any], ctx: RequestContext) -> Dict[str, Any]:
    prompt = param(params, "prompt", str).strip()
    if not prompt:
        raise RPCError(INVALID_PARAMS, "prompt must not be empty")
    duration = float(param(params, "duration_s", (int, float)))
    if not MIN_DURATION <= duration <= MAX_DURATION:
        raise RPCError(INVALID_PARAMS, f"duration_s must be between {MIN_DURATION:g} and {MAX_DURATION:g} seconds")
    seed = int(param(params, "seed", int, required=False, default=0))
    out_path = Path(param(params, "out_path", str)).expanduser()
    if not out_path.is_absolute():
        raise RPCError(INVALID_PARAMS, "out_path must be absolute")
    if out_path.suffix.lower() not in (".wav", ".flac"):
        raise RPCError(INVALID_PARAMS, "out_path must end in .wav or .flac")
    bpm = param(params, "bpm", (int, float), required=False)
    if bpm is not None and not 30 <= bpm <= 300:
        raise RPCError(INVALID_PARAMS, "bpm must be between 30 and 300")
    instrumental = bool(param(params, "instrumental", bool, required=False, default=True))
    lyrics = param(params, "lyrics", str, required=False, default="")
    thinking = bool(param(params, "thinking", bool, required=False, default=False))
    steps = int(param(params, "steps", int, required=False, default=8))
    dit_config = param(params, "model", str, required=False, default=os.environ.get("CLIPPER_MUSIC_MODEL", DEFAULT_DIT))
    device = param(params, "device", str, required=False, default=os.environ.get("CLIPPER_MUSIC_DEVICE", "auto"))

    with _engine.lock:
        ctx.check_cancelled()
        started = time.monotonic()
        base = _engine.load(dit_config, device, ctx)
        if thinking:
            base = _engine.load_lm(ctx, base)
        ctx.check_cancelled()
        load_seconds = time.monotonic() - started

        from acestep.inference import GenerationConfig, GenerationParams, generate_music

        gen_params = GenerationParams(
            task_type="text2music",
            caption=prompt,
            lyrics="[Instrumental]" if instrumental else lyrics,
            instrumental=instrumental,
            bpm=int(round(bpm)) if bpm is not None else None,
            duration=duration,
            seed=seed,
            inference_steps=steps,
            thinking=thinking,
            use_cot_caption=False,
            use_cot_language=False,
        )
        config = GenerationConfig(batch_size=1, use_random_seed=False, seeds=[seed], audio_format="wav")

        # ACE-Step reports 0…1 for the generation itself; map it onto what's left after download/loading.
        def on_progress(value: float, desc: Optional[str] = None, *args: Any, **kwargs: Any) -> None:
            if ctx.cancelled:
                raise Cancelled()  # aborts generation at the next progress point
            try:
                ctx.progress(base + (1 - base) * float(value), desc)
            except (TypeError, ValueError):
                pass

        gen_started = time.monotonic()
        result = generate_music(_engine.dit, _engine.llm, gen_params, config, save_dir=None, progress=on_progress)
        ctx.check_cancelled()
        if not result.success or not result.audios:
            raise RPCError(GENERATION_FAILED, f"ACE-Step generation failed: {result.error or result.status_message}")
        audio = result.audios[0]
        tensor = audio["tensor"]
        sample_rate = int(audio.get("sample_rate", 48000))

        import soundfile as sf

        data = tensor.detach().to("cpu").float().numpy().T  # [samples, channels]
        out_path.parent.mkdir(parents=True, exist_ok=True)
        # Write next to the destination, then rename, so a cancelled or failed write never leaves a partial file.
        fd, tmp = tempfile.mkstemp(suffix=out_path.suffix, dir=out_path.parent)
        os.close(fd)
        try:
            sf.write(tmp, data, sample_rate, subtype="PCM_16" if out_path.suffix.lower() == ".wav" else None)
            os.replace(tmp, out_path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

        elapsed = time.monotonic() - gen_started
        frames = len(data)
        channels = int(data.shape[1]) if data.ndim > 1 else 1
        stats = _peak_memory()
        del result, audio, tensor, data
        _release_caches()
        ctx.progress(1.0, "Done")
        log.info("generated %.1fs of audio in %.1fs (load %.1fs) -> %s", frames / sample_rate, elapsed,
                 load_seconds, out_path)
        return {
            "path": str(out_path),
            "duration_s": frames / sample_rate,
            "sample_rate": sample_rate,
            "channels": channels,
            "model": f"{MODEL_FAMILY} ({dit_config})",
            "seed": seed,
            "bpm": bpm,
            "seconds_elapsed": elapsed,
            "load_seconds": load_seconds,
            "stats": stats,
        }
