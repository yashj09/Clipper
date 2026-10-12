"""Beat and downbeat tracking with beat_this (https://github.com/CPJKU/beat_this, MIT code and weights)."""

from __future__ import annotations

import threading
from pathlib import Path
from typing import Any, Dict

from .methods import param
from .paths import models_dir
from .protocol import INVALID_PARAMS, RPCError, RequestContext

_lock = threading.Lock()
_model = None


def _file2beats():
    global _model
    if _model is None:
        import torch

        # beat_this fetches its checkpoint through torch.hub; keep it with Clipper's other models.
        torch.hub.set_dir(str(models_dir() / "torch-hub"))
        from beat_this.inference import File2Beats

        device = "mps" if torch.backends.mps.is_available() else "cpu"
        _model = File2Beats(checkpoint_path="final0", device=device, dbn=False)
    return _model


def track(params: Dict[str, Any], ctx: RequestContext) -> Dict[str, Any]:
    path = Path(param(params, "path", str)).expanduser()
    if not path.is_file():
        raise RPCError(INVALID_PARAMS, f"No such file: {path}")
    with _lock:
        ctx.progress(0.0, "Tracking beats")
        beats, downbeats = _file2beats()(str(path))
    beats = [float(b) for b in beats]
    intervals = sorted(b - a for a, b in zip(beats, beats[1:]) if b > a)
    bpm = 60.0 / intervals[len(intervals) // 2] if intervals else 0.0
    return {"beats": beats, "downbeats": [float(d) for d in downbeats], "bpm": bpm, "model": "beat_this final0"}
