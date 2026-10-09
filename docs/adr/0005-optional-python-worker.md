# ADR 0005: Optional Python worker for tools that only exist in Python

**Status:** Accepted, 2026-10-10

## Decision
`worker/` is a uv-managed Python project. It is started on demand and speaks JSON-RPC 2.0 over stdio. It hosts beat_this, librosa, PySceneDetect and ACE-Step. The core app never requires it: Swift fallbacks exist for beats and scene cuts.

## Why
The best permissively licensed beat tracking and music generation tools are Python-only. Isolating them in a separate process keeps the app bundle lean and avoids license entanglement. Models are downloaded only when the user enables a feature that needs them.
