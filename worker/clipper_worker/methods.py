"""Method table. Heavy libraries (torch, ACE-Step, beat_this) are imported only inside the methods that need them."""

from __future__ import annotations

import importlib.metadata
import importlib.util
import platform
from typing import Any, Dict

from . import __version__
from .paths import models_dir
from .protocol import FEATURE_NOT_INSTALLED, INVALID_PARAMS, RPCError, RequestContext

_torch_info: Dict[str, Any] | None = None


def _installed(module: str) -> bool:
    try:
        return importlib.util.find_spec(module) is not None
    except (ImportError, ValueError):
        return False


def _dist_version(name: str) -> str | None:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return None


def _torch() -> Dict[str, Any]:
    """torch version and MPS availability (imports torch once, only if installed)."""
    global _torch_info
    if _torch_info is None:
        info: Dict[str, Any] = {"torch": None, "mps": False}
        if _installed("torch"):
            import torch

            info = {"torch": torch.__version__, "mps": bool(torch.backends.mps.is_available())}
        _torch_info = info
    return _torch_info


def require_feature(available: bool, feature: str, extra: str) -> None:
    if not available:
        raise RPCError(
            FEATURE_NOT_INSTALLED,
            f"{feature} isn't installed in the worker environment. Install it with "
            f"`uv sync --extra {extra}` in the worker directory (or launch with `uv run --extra {extra}`).",
            {"extra": extra},
        )


def param(params: Dict[str, Any], name: str, kind: type | tuple, required: bool = True, default: Any = None) -> Any:
    if name not in params or params[name] is None:
        if required:
            raise RPCError(INVALID_PARAMS, f"Missing required param '{name}'")
        return default
    value = params[name]
    # bool is an int subclass; don't let `true` pass as a number.
    if isinstance(value, bool) and bool not in (kind if isinstance(kind, tuple) else (kind,)):
        raise RPCError(INVALID_PARAMS, f"Param '{name}' has the wrong type (got bool)")
    if not isinstance(value, kind):
        raise RPCError(INVALID_PARAMS, f"Param '{name}' has the wrong type (got {type(value).__name__})")
    return value


def ping(params: Dict[str, Any], ctx: RequestContext) -> Dict[str, Any]:
    return {"version": __version__, "python": platform.python_version(), **_torch()}


def capabilities(params: Dict[str, Any], ctx: RequestContext) -> Dict[str, Any]:
    from .music import MODEL_FAMILY, main_model_downloaded

    music = _installed("acestep")
    return {
        "music_generation": music,
        "music_model": MODEL_FAMILY if music else None,
        "music_model_downloaded": music and main_model_downloaded(),
        "beat_this": _installed("beat_this"),
        "models_dir": str(models_dir()),
        "packages": {
            name: _dist_version(name) for name in ("ace-step", "beat-this", "torch", "mlx")
            if _dist_version(name) is not None
        },
    }


def generate_music(params: Dict[str, Any], ctx: RequestContext) -> Dict[str, Any]:
    require_feature(_installed("acestep"), "Music generation (ACE-Step)", "music")
    from .music import generate

    return generate(params, ctx)


def beats(params: Dict[str, Any], ctx: RequestContext) -> Dict[str, Any]:
    require_feature(_installed("beat_this"), "Beat tracking (beat_this)", "beats")
    from .beats import track

    return track(params, ctx)


HANDLERS = {
    "ping": ping,
    "capabilities": capabilities,
    "generate_music": generate_music,
    "beats": beats,
}
