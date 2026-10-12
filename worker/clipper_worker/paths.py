"""Where downloaded model weights live."""

from __future__ import annotations

import os
from pathlib import Path


def models_dir() -> Path:
    """`$CLIPPER_MODELS`, else `~/Library/Application Support/Clipper/models`."""
    env = os.environ.get("CLIPPER_MODELS")
    if env:
        return Path(env).expanduser().resolve()
    return Path.home() / "Library" / "Application Support" / "Clipper" / "models"
